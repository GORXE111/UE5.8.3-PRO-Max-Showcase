#include "Engine/Engine.h"
#include "Engine/World.h"
#include "HAL/PlatformMisc.h"
#include "Misc/CommandLine.h"
#include "Misc/CoreDelegates.h"
#include "Misc/Parse.h"
#include "Modules/ModuleManager.h"
#include "UObject/Package.h"

class FAdoptionSmokeModule final : public FDefaultGameModuleImpl
{
public:
    void StartupModule() override
    {
        if (FParse::Param(FCommandLine::Get(), TEXT("AdoptionSmoke")))
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
                World->GetOutermost()->GetName() == TEXT("/Engine/Maps/Entry"))
            {
                FCoreDelegates::OnEndFrame.Remove(EndFrame);
                UE_LOG(LogTemp, Display, TEXT("UE_ADOPTION_SMOKE_WORLD_READY /Engine/Maps/Entry"));
                FPlatformMisc::RequestExit(false);
                return;
            }
        }
    }

    FDelegateHandle EndFrame;
};

IMPLEMENT_PRIMARY_GAME_MODULE(FAdoptionSmokeModule, SampleGame, "SampleGame");
