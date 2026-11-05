"""Exercise the pinned Windows release store with a real packaged adoption sample."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
from threading import Timer


INFRASTRUCTURE_REVISION = "2d0654e54b78aeed17161747c6deedb9dce3d0b1"
ENTRY = "SampleGame/Binaries/Win64/SampleGame.exe"
MAIN_PAK = "SampleGame/Content/Paks/SampleGame-Windows.pak"
COOKED_ASSET = "SampleGame/Content/Release/AdoptionCooked.uasset"
MARKER = "SampleGame/Content/Release/adoption-version.json"
SAVE = "Saved/SaveGames/AdoptionUpdateSmoke.txt"
MAX_PAYLOAD = 2 * 1024**3
FREE_RESERVE = 128 * 1024**2
GAME_FLAGS = ("-NullRHI", "-Unattended", "-NoSound")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load_infrastructure(root):
    def git(*args):
        return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True,
                              text=True, timeout=30).stdout.strip()

    require(git("rev-parse", "HEAD") == INFRASTRUCTURE_REVISION,
            f"Use the reviewed infrastructure revision {INFRASTRUCTURE_REVISION}")
    require(not git("status", "--porcelain", "--untracked-files=all", "--ignored", "--",
                    "Tools/Release/ReleaseSets"), "Use clean infrastructure release-set inputs")
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(root / "Tools/Release/ReleaseSets"))
    import release_set
    import windows_player

    return release_set, windows_player


def payload_inventory(archive, sets):
    records = []
    total = 0
    sets.plain(archive, True)
    for folder in ("Engine", "SampleGame"):
        root = sets.child(archive, folder)
        sets.plain(root, True)
        for directory, children, filenames in os.walk(root, followlinks=False):
            for name in children[:]:
                sets.plain(Path(directory) / name, True)
                # A previous packaged launch can leave Unreal config and logs here.
                if name.lower() in {"saved", "savegames", ".release-sets"}:
                    children.remove(name)
            for name in filenames:
                path = Path(directory) / name
                sets.plain(path)
                relative = sets.relative(path.relative_to(archive).as_posix())
                require(relative.lower() != MARKER.lower(), "Archive contains a pre-existing fixture marker")
                size = path.stat().st_size
                require(0 < size <= sets.MAX_FILE, f"Invalid archive file size: {relative}")
                total += size
                require(total <= MAX_PAYLOAD and len(records) < sets.MAX_FILES - 1,
                        "Archive exceeds the sample fixture size or file-count budget")
                role = "support"
                if path.suffix.lower() in {".exe", ".dll"}:
                    role = "native"
                elif relative.startswith("SampleGame/Content/Paks/") and path.suffix == ".pak":
                    role = "content"
                records.append(dict(path=relative, role=role, size=size, sha256=sets.digest(path)))
    require(any(item["path"] == ENTRY for item in records), "Missing packaged SampleGame.exe")
    require(any(item["role"] == "content" for item in records), "Missing packaged SampleGame PAK")
    return records, total


def fixture_manifest(source, records, trust, release, native_hash, sets):
    marker = sets.child(source, MARKER)
    marker.parent.mkdir(parents=True, exist_ok=True)
    raw = sets.canonical(dict(releaseId=release, saveSchema=1, healthy=release != 102))
    marker.write_bytes(raw)
    marker_record = dict(path=MARKER, role="support", size=len(raw), sha256=hashlib.sha256(raw).hexdigest())
    value = dict(format=1, kind="samplegame-release-set", **{key: trust[key] for key in sets.BINDINGS},
                 releaseId=release, minLoaderVersion=1, sourceCommit=INFRASTRUCTURE_REVISION,
                 nativeSourceHash=native_hash, files=sorted([*records, marker_record], key=lambda item: item["path"]),
                 save=dict(schema=1, readable=[1], migrations=[]))
    value["buildId"] = sets.build_id(value)
    return sets.canonical(value)


def save_bytes(selected, sets):
    return sets.read_bounded(sets.child(selected["savesRoot"], SAVE), 16)


def verify_boot(store, selected, release, player, sets, expected_pair):
    require(selected["reference"]["releaseId"] == release, f"Expected release {release} at boot")
    process = None
    watchdog = None

    def start(*args, **kwargs):
        # The production launcher controls selection, ticketing, health and confirmation.
        # Its startup limit ends at health; also cap the full process lifetime.
        nonlocal process, watchdog
        process = subprocess.Popen(*args, **kwargs, creationflags=subprocess.CREATE_NO_WINDOW)
        watchdog = Timer(135, process.kill)
        watchdog.daemon = True
        watchdog.start()
        return process

    try:
        player.launch(store, selected, user_args=GAME_FLAGS, popen=start, startup_timeout=120)
    except ValueError as error:
        if release != 102 or str(error) != "Selected game exited with status 42":
            raise
    finally:
        if watchdog is not None:
            watchdog.cancel()
            watchdog.join()

    boot = sets.child(store.root, f"boots/{selected['attemptId']}")
    result = sets.parse(sets.read_bounded(boot / "result.json", 16384), 16384)
    log = sets.read_bounded(boot / "game.log", 8 * 1024**2).decode("utf-8-sig", errors="replace")
    files = selected["manifest"]["files"]
    require(any(f"Mounted Pak file '../../../{item['path']}'" in log for item in files
                if item["role"] == "content" and (expected_pair is None or item["path"] == MAIN_PAK)),
            f"Release {release} did not log the expected SampleGame PAK mount")
    pair_evidence = {}
    if expected_pair is not None:
        hashes = {item["path"]: item["sha256"] for item in files}
        require(hashes.get(ENTRY) == expected_pair["executableSha256"]
                and hashes.get(MAIN_PAK) == expected_pair["pakSha256"],
                f"Release {release} did not select its signed executable and PAK pair")
        pairs = re.findall(r"(?m)LogTemp: Display: UE_ADOPTION_UPDATE_SMOKE_PAIR native=([0-9]+) cooked=([0-9]+)\r?$", log)
        require(pairs == [(str(release), str(release))],
                f"Release {release} did not log one matching compiled and cooked release identity")
        native, cooked = map(int, pairs[0])
        pair_evidence = dict(nativeRelease=native, cookedRelease=cooked,
                             executableSha256=hashes[ENTRY], pakSha256=hashes[MAIN_PAK])
    written_save = save_bytes(selected, sets)
    require(written_save == f"{release}\n".encode("ascii"),
            f"Release {release} did not write its expected save bytes")

    expected_exit = 42 if release == 102 else 0
    require(process is not None and process.returncode == expected_exit,
            f"Release {release} did not exit with status {expected_exit}")
    ack_path = boot / "health.json"
    if release == 102:
        require(result == {"status": "rolled-back", "reason": "Selected game exited with status 42"}
                and not os.path.lexists(ack_path), "Fault candidate did not roll back before health")
        require("UE_ADOPTION_UPDATE_SMOKE_FAULT release=102" in log, "Missing intentional fault log marker")
    else:
        ticket = sets.parse(sets.read_bounded(boot / "ticket.json", 8192), 8192)
        ack = json.loads(sets.read_bounded(ack_path, 8192).decode("utf-8"))
        player.acknowledgement(ack, ticket, process.pid)
        require(result == {"status": "confirmed", "exitCode": 0, "health": ack}
                and ack["luaVersion"] == f"adoption-sample-{release}", "Missing confirmed sample health")
        require(f"UE_ADOPTION_UPDATE_SMOKE_HEALTHY release={release}" in log and "LogExit: Exiting." in log,
                f"Release {release} did not log a healthy game world and normal exit")
    return dict(releaseId=release, attemptId=selected["attemptId"], exitCode=expected_exit,
                manifestSha256=selected["reference"]["manifestSha256"], buildId=selected["manifest"]["buildId"],
                saveGeneration=selected["reference"]["saveGeneration"], saveBytes=written_save.decode("ascii"),
                evidence=boot.relative_to(store.root.parent).as_posix(), launcherStatus=result["status"], **pair_evidence)


def run(archives, infrastructure, output, report):
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

    sets, player = load_infrastructure(infrastructure)
    variant_mode = len(archives) > 1
    inventories = {release: payload_inventory(path, sets) for release, path in archives.items()}
    base_records, base_size = inventories[100]
    sizes = [inventories.get(release, inventories[100])[1] for release in (100, 101, 102)]
    require(shutil.disk_usage(output).free >= sum(sizes) + max(sizes) + FREE_RESERVE,
            "Insufficient free space for three complete releases and one temporary staging copy")
    native_hash = next(item["sha256"] for item in base_records if item["path"] == ENTRY)
    pairs = {}
    if variant_mode:
        for release, (records, size) in inventories.items():
            hashes = {item["path"]: item["sha256"] for item in records}
            require(MAIN_PAK in hashes, f"Release {release} is missing {MAIN_PAK}")
            require(all(path.lower() != COOKED_ASSET.lower() for path in hashes),
                    f"Release {release} contains a loose copy of the cooked proof asset")
            pairs[release] = dict(executableSha256=hashes[ENTRY], pakSha256=hashes[MAIN_PAK], packagedPayloadBytes=size)
        for field in ("executableSha256", "pakSha256"):
            require(len({pair[field] for pair in pairs.values()}) == len(pairs),
                    f"The base and both candidates must have distinct {field} values")
        report["releaseArchives"] = pairs
    trust = dict(projectId="SampleGame", platform="Windows", channel="adoption-smoke", baseReleaseId=100,
                 engineBuildId="win64-adoption-fixture", shellCompatibilityId=native_hash, loaderVersion=1)
    private_key = Ed25519PrivateKey.generate()
    public_key = private_key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex()
    verifier = sets.ed25519_verifier(public_key)
    report.update(infrastructureRevision=INFRASTRUCTURE_REVISION, publicKeyHex=public_key,
                  packagedExeSha256=native_hash, packagedPayloadBytes=base_size, sameExeAndPaksAcrossReleases=not variant_mode)
    store_root = output / "store"

    for release in (100, 101, 102):
        archive = archives.get(release, archives[100])
        records, _ = inventories.get(release, inventories[100])
        release_native_hash = pairs[release]["executableSha256"] if variant_mode else native_hash
        with TemporaryDirectory(prefix="stage-", dir=output) as scratch:
            source = Path(scratch)
            for item in records:
                target = sets.child(source, item["path"])
                target.parent.mkdir(parents=True, exist_ok=True)
                sets.copy_verified_payload(sets.child(archive, item["path"]), target, item)
            raw = fixture_manifest(source, records, trust, release, release_native_hash, sets)
            if release == 100:
                trust["baseManifestSha256"] = hashlib.sha256(raw).hexdigest()
                report["baseManifestSha256"] = trust["baseManifestSha256"]
            with sets.ReleaseSetStore(store_root, trust, verifier).lease() as store:
                if release == 100:
                    store.initialize(source, raw)
                else:
                    store.stage(source, raw, private_key.sign(raw))
                    store.activate(release)
                selected = store.boot()
                if release != 100:
                    require(save_bytes(selected, sets) == f"{release - 1}\n".encode("ascii"),
                            f"Release {release} did not inherit its predecessor's save bytes")
                report["boots"].append(verify_boot(store, selected, release, player, sets, pairs.get(release)))
                if release == 101:
                    confirmed = selected

    # Verify the prior bytes before launching recovery, since recovery writes them again.
    require(save_bytes(confirmed, sets) == b"101\n", "Fault candidate changed the confirmed save generation")
    with sets.ReleaseSetStore(store_root, trust, verifier).lease() as store:
        recovered = store.boot()
        require(recovered["reference"] == confirmed["reference"] and save_bytes(recovered, sets) == b"101\n",
                "Cold recovery did not select the prior signed release and its exact save generation")
        report["boots"].append(verify_boot(store, recovered, 101, player, sets, pairs.get(101)))
        state = sets.parse(sets.read_bounded(store_root / "state.json", 65536), 65536)
        require(state["active"] == confirmed["reference"] and state["blocked"] == [102] and state["boot"] is None,
                "Release store did not retain confirmed recovery and block the failed release")

    report.update(confirmedRelease=101, rejectedRelease=102, preservedSave=True, status="win64-signed-update-passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True, help="UAT Archive/Windows for the adoption sample")
    parser.add_argument("--candidate-archive", action="append", default=[], metavar="RELEASE=PATH",
                        help="UAT Archive/Windows for a different build; supply both 101=PATH and 102=PATH")
    parser.add_argument("--infrastructure", type=Path, required=True, help="Pinned infrastructure checkout")
    parser.add_argument("--output", type=Path, required=True, help="New directory for the disposable store and report")
    args = parser.parse_args()
    report = dict(schemaVersion=1, status="blocked", fixturePayloads=True, networkUsed=False, boots=[])
    output_created = False
    try:
        require(os.name == "nt", "The packaged Win64 smoke requires Windows")
        archives = {100: args.archive.absolute()}
        for candidate in args.candidate_archive:
            release, separator, path = candidate.partition("=")
            require(separator and release in {"101", "102"} and path,
                    "Use --candidate-archive 101=PATH and --candidate-archive 102=PATH")
            release_id = int(release)
            require(release_id not in archives, f"Duplicate archive for release {release_id}")
            archives[release_id] = Path(path).absolute()
        require(len(archives) in {1, 3}, "Supply both candidate archives or neither")
        infrastructure = args.infrastructure.resolve(strict=True)
        output = args.output.resolve()
        resolved_archives = {path.resolve(strict=True) for path in archives.values()}
        require(len(resolved_archives) == len(archives), "Provide a separate archive for each release")
        require(all(not output.is_relative_to(path) for path in resolved_archives) and not output.is_relative_to(infrastructure),
                "Output must be outside the archives and the infrastructure checkout")
        output.mkdir()
        output_created = True
        run(archives, infrastructure, output, report)
    except (OSError, ValueError, ImportError, subprocess.SubprocessError) as error:
        report.update(error=str(error))
    rendered = json.dumps(report, indent=2, ensure_ascii=True) + "\n"
    if output_created:
        (output / "report.json").write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0 if report["status"] == "win64-signed-update-passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
