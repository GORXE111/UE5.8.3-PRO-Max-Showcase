#include "Dom/JsonObject.h"
#include "Engine/DataTable.h"
#include "Engine/Engine.h"
#include "Engine/World.h"
#include "GenericPlatform/GenericPlatformFile.h"
#include "HAL/FileManager.h"
#include "HAL/PlatformFileManager.h"
#include "HAL/PlatformMisc.h"
#include "HAL/PlatformProcess.h"
#include "Misc/CommandLine.h"
#include "Misc/CoreDelegates.h"
#include "Misc/FileHelper.h"
#include "Misc/Parse.h"
#include "Misc/Paths.h"
#include "Modules/ModuleManager.h"
#include "Serialization/JsonSerializer.h"
#include "UObject/Package.h"

#if __has_include("AdoptionFixtureVersion.h")
#include "AdoptionFixtureVersion.h"
#endif

namespace
{
    constexpr const TCHAR* ExpectedMap = TEXT("/Engine/Maps/Entry");

    FString FullPath(const FString& Path)
    {
        FString Result = FPaths::ConvertRelativePathToFull(Path);
        FPaths::NormalizeDirectoryName(Result);
        return Result;
    }

    bool SamePath(const FString& First, const FString& Second)
    {
        return FullPath(First).Equals(FullPath(Second), ESearchCase::IgnoreCase);
    }

    bool IsLowerHex(const FString& Value, int32 Length)
    {
        if (Value.Len() != Length)
        {
            return false;
        }
        for (TCHAR Character : Value)
        {
            if (!(Character >= '0' && Character <= '9') && !(Character >= 'a' && Character <= 'f'))
            {
                return false;
            }
        }
        return true;
    }

    TSharedPtr<FJsonObject> ReadJson(const FString& Path)
    {
        const int64 Size = IFileManager::Get().FileSize(*Path);
        FString Text;
        TSharedPtr<FJsonObject> Object;
        if (Size <= 0 || Size > 8192 || !FFileHelper::LoadFileToString(Text, *Path) ||
            !FJsonSerializer::Deserialize(TJsonReaderFactory<>::Create(Text), Object))
        {
            return nullptr;
        }
        return Object;
    }

    struct FUpdateSmokeTicket
    {
        FString AttemptId;
        FString ManifestSha256;
        FString BuildId;
        FString PayloadRoot;
        FString UserRoot;
        FString AckPath;
        int32 ReleaseId = 0;
        int32 SaveSchema = 0;

        bool Load(const FString& TicketPath)
        {
            const TSharedPtr<FJsonObject> Ticket = ReadJson(TicketPath);
            FString CommandUserDir;
            if (!Ticket || Ticket->Values.Num() != 8 || FPaths::IsRelative(TicketPath) ||
                !Ticket->TryGetStringField(TEXT("attemptId"), AttemptId) || !IsLowerHex(AttemptId, 32) ||
                !Ticket->TryGetStringField(TEXT("manifestSha256"), ManifestSha256) || !IsLowerHex(ManifestSha256, 64) ||
                !Ticket->TryGetStringField(TEXT("buildId"), BuildId) || !IsLowerHex(BuildId, 64) ||
                !Ticket->TryGetStringField(TEXT("payloadRoot"), PayloadRoot) || FPaths::IsRelative(PayloadRoot) ||
                !Ticket->TryGetStringField(TEXT("userRoot"), UserRoot) || FPaths::IsRelative(UserRoot) ||
                !Ticket->TryGetStringField(TEXT("ackPath"), AckPath) || FPaths::IsRelative(AckPath) ||
                !Ticket->TryGetNumberField(TEXT("releaseId"), ReleaseId) || ReleaseId < 100 || ReleaseId > 102 ||
                !Ticket->TryGetNumberField(TEXT("saveSchema"), SaveSchema) || SaveSchema < 1 || SaveSchema > 10000 ||
                !FParse::Value(FCommandLine::Get(), TEXT("UserDir="), CommandUserDir) || FPaths::IsRelative(CommandUserDir))
            {
                return false;
            }

            const FString AttemptRoot = FPaths::GetPath(FullPath(TicketPath));
            const FString StoreRoot = FPaths::GetPath(FPaths::GetPath(AttemptRoot));
            const FString SaveGeneration = FPaths::GetCleanFilename(FullPath(UserRoot));
            return SaveGeneration.StartsWith(TEXT("g-"), ESearchCase::CaseSensitive) &&
                IsLowerHex(SaveGeneration.RightChop(2), 32) &&
                SamePath(TicketPath, FPaths::Combine(StoreRoot, TEXT("boots"), AttemptId, TEXT("ticket.json"))) &&
                SamePath(AckPath, FPaths::Combine(AttemptRoot, TEXT("health.json"))) &&
                SamePath(PayloadRoot, FPaths::Combine(StoreRoot, TEXT("versions"), FString::FromInt(ReleaseId))) &&
                SamePath(UserRoot, FPaths::Combine(StoreRoot, TEXT("saves"), SaveGeneration)) &&
                SamePath(UserRoot, CommandUserDir) && SamePath(UserRoot, FPaths::ProjectUserDir()) &&
                SamePath(FPaths::Combine(UserRoot, TEXT("Saved")), FPaths::ProjectSavedDir()) &&
                SamePath(FPaths::Combine(PayloadRoot, TEXT("SampleGame/Binaries/Win64")), FPlatformProcess::BaseDir()) &&
                SamePath(FPaths::Combine(PayloadRoot, TEXT("SampleGame/Content")), FPaths::ProjectContentDir());
        }

        bool WriteAcknowledgement() const
        {
            const TSharedRef<FJsonObject> Ack = MakeShared<FJsonObject>();
            Ack->SetNumberField(TEXT("format"), 1);
            Ack->SetStringField(TEXT("attemptId"), AttemptId);
            Ack->SetNumberField(TEXT("releaseId"), ReleaseId);
            Ack->SetStringField(TEXT("manifestSha256"), ManifestSha256);
            Ack->SetStringField(TEXT("buildId"), BuildId);
            Ack->SetNumberField(TEXT("saveSchema"), SaveSchema);
            Ack->SetNumberField(TEXT("pid"), FPlatformProcess::GetCurrentProcessId());
            Ack->SetStringField(TEXT("userRoot"), UserRoot);
            // The sample contains no Lua runtime. The pinned launcher still requires this field.
            Ack->SetStringField(TEXT("luaVersion"), FString::Printf(TEXT("adoption-sample-%d"), ReleaseId));

            FString Text;
            const FString TempPath = AckPath + TEXT(".tmp");
            IPlatformFile& Files = FPlatformFileManager::Get().GetPlatformFile();
            if (!FJsonSerializer::Serialize(Ack, TJsonWriterFactory<>::Create(&Text)) ||
                !FFileHelper::SaveStringToFile(Text, *TempPath, FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM,
                    &IFileManager::Get(), FILEWRITE_NoReplaceExisting))
            {
                return false;
            }
            // Windows publishes the completed acknowledgement with a same-directory rename.
            if (!Files.MoveFile(*AckPath, *TempPath))
            {
                Files.DeleteFile(*TempPath);
                return false;
            }
            return true;
        }
    };

    bool UpdateSaveFixture(int32 ReleaseId)
    {
        IFileManager& Files = IFileManager::Get();
        const FString SaveDirectory = FPaths::Combine(FPaths::ProjectSavedDir(), TEXT("SaveGames"));
        const FString SavePath = FPaths::Combine(SaveDirectory, TEXT("AdoptionUpdateSmoke.txt"));
        const FString NextSave = FString::Printf(TEXT("%d\n"), ReleaseId);
        const int64 Size = Files.FileSize(*SavePath);
        if (Size < 0)
        {
            if (ReleaseId != 100 || !Files.MakeDirectory(*SaveDirectory, true))
            {
                return false;
            }
        }
        else
        {
            FString PreviousSave;
            if (Size != 4 || !FFileHelper::LoadFileToString(PreviousSave, *SavePath))
            {
                return false;
            }
            if (ReleaseId != 102 && PreviousSave == NextSave)
            {
                return true;
            }
            if (PreviousSave != FString::Printf(TEXT("%d\n"), ReleaseId - 1) || ReleaseId == 100)
            {
                return false;
            }
        }
        return FFileHelper::SaveStringToFile(NextSave, *SavePath, FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM);
    }

    uint8 RunUpdateSmoke(const FString& TicketPath)
    {
        FUpdateSmokeTicket Ticket;
        if (!Ticket.Load(TicketPath))
        {
            UE_LOG(LogTemp, Error, TEXT("UE_ADOPTION_UPDATE_SMOKE_ERROR invalid ticket or launch roots"));
            return 1;
        }

        const TSharedPtr<FJsonObject> Marker = ReadJson(FPaths::Combine(FPaths::ProjectContentDir(),
            TEXT("Release/adoption-version.json")));
        int32 ReleaseId = 0;
        int32 SaveSchema = 0;
        bool bHealthy = false;
        if (!Marker || Marker->Values.Num() != 3 ||
            !Marker->TryGetNumberField(TEXT("releaseId"), ReleaseId) || ReleaseId != Ticket.ReleaseId ||
            !Marker->TryGetNumberField(TEXT("saveSchema"), SaveSchema) || SaveSchema != Ticket.SaveSchema ||
            !Marker->TryGetBoolField(TEXT("healthy"), bHealthy) || bHealthy != (ReleaseId != 102))
        {
            UE_LOG(LogTemp, Error, TEXT("UE_ADOPTION_UPDATE_SMOKE_ERROR selected payload marker differs from ticket"));
            return 1;
        }
#if defined(UE_ADOPTION_FIXTURE_RELEASE)
        const UDataTable* Table = LoadObject<UDataTable>(nullptr,
            TEXT("/Game/Release/AdoptionCooked.AdoptionCooked"));
        const TArray<FName> Rows = Table ? Table->GetRowNames() : TArray<FName>();
        const FName ExpectedRow(*FString::Printf(TEXT("Release%d"), ReleaseId));
        if (ReleaseId != UE_ADOPTION_FIXTURE_RELEASE || Rows.Num() != 1 || Rows[0] != ExpectedRow)
        {
            UE_LOG(LogTemp, Error, TEXT("UE_ADOPTION_UPDATE_SMOKE_ERROR native=%d ticket=%d cooked=%s"),
                UE_ADOPTION_FIXTURE_RELEASE, ReleaseId, Rows.Num() == 1 ? *Rows[0].ToString() : TEXT("missing or ambiguous"));
            return 1;
        }
        UE_LOG(LogTemp, Display, TEXT("UE_ADOPTION_UPDATE_SMOKE_PAIR native=%d cooked=%s"),
            UE_ADOPTION_FIXTURE_RELEASE, *Rows[0].ToString().RightChop(7));
#endif
        if (!UpdateSaveFixture(ReleaseId))
        {
            UE_LOG(LogTemp, Error, TEXT("UE_ADOPTION_UPDATE_SMOKE_ERROR save migration failed for release %d"), ReleaseId);
            return 1;
        }
        if (!bHealthy)
        {
            UE_LOG(LogTemp, Display, TEXT("UE_ADOPTION_UPDATE_SMOKE_FAULT release=%d"), ReleaseId);
            return 42;
        }
        if (!Ticket.WriteAcknowledgement())
        {
            UE_LOG(LogTemp, Error, TEXT("UE_ADOPTION_UPDATE_SMOKE_ERROR could not publish health acknowledgement"));
            return 1;
        }

        UE_LOG(LogTemp, Display, TEXT("UE_ADOPTION_UPDATE_SMOKE_HEALTHY release=%d"), ReleaseId);
        return 0;
    }
}

class FAdoptionSmokeModule final : public FDefaultGameModuleImpl
{
public:
    void StartupModule() override
    {
        bHasReleaseTicket = FParse::Value(FCommandLine::Get(), TEXT("SampleGameReleaseTicket="), ReleaseTicketPath);
        if (bHasReleaseTicket || FParse::Param(FCommandLine::Get(), TEXT("AdoptionSmoke")))
        {
            EndFrame = FCoreDelegates::OnEndFrame.AddRaw(this, &FAdoptionSmokeModule::CheckGameWorld);
        }
    }

    void ShutdownModule() override
    {
        FCoreDelegates::OnEndFrame.Remove(EndFrame);
    }

private:
    void CheckGameWorld()
    {
        if (!GEngine)
        {
            return;
        }

        for (const FWorldContext& Context : GEngine->GetWorldContexts())
        {
            const UWorld* World = Context.World();
            if (Context.WorldType == EWorldType::Game && World && World->HasBegunPlay() &&
                World->GetOutermost()->GetName() == ExpectedMap)
            {
                FCoreDelegates::OnEndFrame.Remove(EndFrame);
                UE_LOG(LogTemp, Display, TEXT("UE_ADOPTION_SMOKE_WORLD_READY /Engine/Maps/Entry"));
                if (bHasReleaseTicket)
                {
                    const uint8 Status = RunUpdateSmoke(ReleaseTicketPath);
                    if (Status != 0)
                    {
                        // GuardedMain can leave before pumping WM_QUIT. Preserve the fault status.
                        FPlatformMisc::RequestExitWithStatus(true, Status, TEXT("AdoptionUpdateSmoke"));
                        return;
                    }
                }
                FPlatformMisc::RequestExit(false);
                return;
            }
        }
    }

    FDelegateHandle EndFrame;
    FString ReleaseTicketPath;
    bool bHasReleaseTicket = false;
};

IMPLEMENT_PRIMARY_GAME_MODULE(FAdoptionSmokeModule, SampleGame, "SampleGame");
