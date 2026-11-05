"""Exercise the production Windows player with real archives over loopback HTTPS."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

from loopback_feed import CURRENT, UPDATES, LoopbackFeed
import verify_update as fixture


def boot_dirs(store_root):
    boots = store_root / "boots"
    return {path.name for path in boots.iterdir()} if boots.is_dir() else set()


def run_player(root, config, player, sets, release, pair, **options):
    store_root = player.store_root(root, config)
    before = boot_dirs(store_root)
    try:
        fixture.require(player.run(root, user_args=fixture.GAME_FLAGS, **options) == 0,
                        "Expected the Windows player to exit normally")
        fixture.require(release != 102, "Intentional fault was not rejected")
    except ValueError as error:
        if release != 102 or str(error) != "Selected game exited with status 42":
            raise

    created = boot_dirs(store_root) - before
    fixture.require(len(created) == 1, "Expected exactly one new game boot")
    attempt = created.pop()
    boot = sets.child(store_root, f"boots/{attempt}")
    ticket = sets.parse(sets.read_bounded(boot / "ticket.json", 8192), 8192)
    store = sets.ReleaseSetStore(store_root, config["trust"], sets.ed25519_verifier(config["publicKeyHex"]))
    with store.lease():
        state = store._state()
        manifest, digest, _ = store._read_version(release)
        reference = dict(releaseId=release, manifestSha256=digest, saveGeneration=Path(ticket["userRoot"]).name)
        fixture.require(ticket["releaseId"] == release and ticket["attemptId"] == attempt
                        and ticket["manifestSha256"] == digest and state["boot"] is None,
                        "Boot ticket did not match the verified release")
        fixture.require((release in state["blocked"]) if release == 102 else (state["active"] == reference),
                        "Release state did not match the boot result")
        selected = dict(attemptId=attempt, reference=reference, manifest=manifest, savesRoot=ticket["userRoot"])
        evidence = fixture.inspect_boot(store, selected, release, player, sets, pair)
        evidence["evidence"] = boot.relative_to(root.parent).as_posix()
        return evidence


def publish(feed, archive, release, records, pairs, trust, key, workspace, sets):
    workspace.mkdir()
    raw = fixture.fixture_manifest(workspace, records, trust, release, pairs[release]["executableSha256"], sets)
    files = {item["path"]: sets.child(archive, item["path"]) for item in records}
    files[fixture.MARKER] = sets.child(workspace, fixture.MARKER)
    feed.publish(release, raw, key.sign(raw), files)


def verify_payload_receipts(receipts, release, records):
    prefix = f"{UPDATES}/versions/{release}/payload/"
    completed = {item["path"].removeprefix(prefix): item["bytesSent"] for item in receipts
                 if item["path"].startswith(prefix) and item["status"] == 200}
    sizes = {item["path"]: item["size"] for item in records}
    fixture.require(completed.keys() == sizes.keys() | {fixture.MARKER}
                    and all(completed[name] == size for name, size in sizes.items()),
                    f"HTTPS receipts did not cover the whole signed release {release}")
    return dict(payloadFiles=len(completed), payloadBytes=sum(completed.values()))


def run(archives, infrastructure, output, report):
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

    sets, player = fixture.load_infrastructure(infrastructure)
    inventories = {release: fixture.payload_inventory(path, sets) for release, path in archives.items()}
    records = {release: items for release, (items, _) in inventories.items()}
    fixture.require(shutil.disk_usage(output).free >= 2 * sum(size for _, size in inventories.values()) + fixture.FREE_RESERVE,
                    "Insufficient space for the base, download cache and verified release sets")
    pairs = {}
    for release, items in records.items():
        hashes = {item["path"]: item["sha256"] for item in items}
        fixture.require(fixture.MAIN_PAK in hashes and fixture.COOKED_ASSET.lower() not in {name.lower() for name in hashes},
                        f"Release {release} must contain the packaged proof PAK")
        pairs[release] = dict(executableSha256=hashes[fixture.ENTRY], pakSha256=hashes[fixture.MAIN_PAK])
    fixture.require(all(len({pair[field] for pair in pairs.values()}) == 3 for field in ("executableSha256", "pakSha256")),
                    "Use three distinct EXE and PAK archives from the native and asset smoke")
    base_exe = pairs[100]["executableSha256"]
    key = Ed25519PrivateKey.generate()
    public_key = key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex()
    trust = dict(projectId="SampleGame", platform="Windows", channel="adoption-smoke", baseReleaseId=100,
                 engineBuildId="win64-adoption-fixture", shellCompatibilityId=base_exe, loaderVersion=1)
    root = output / "installation"
    base = root / "base"
    payload = base / "payload"
    payload.mkdir(parents=True)
    fixture.copy_payload(archives[100], payload, records[100], sets)
    raw = fixture.fixture_manifest(payload, records[100], trust, 100, base_exe, sets)
    (base / "manifest.json").write_bytes(raw)
    trust["baseManifestSha256"] = hashlib.sha256(raw).hexdigest()
    empty_saves = output / "empty-import"
    empty_saves.mkdir()
    with LoopbackFeed(output) as feed:
        config = dict(format=2, trust=trust, publicKeyHex=public_key, manifestUrl=feed.manifest_url, allowOffline=True)
        (root / "release-player.json").write_bytes(sets.canonical(config))
        report.update(manifestUrl=feed.manifest_url, infrastructureRevision=fixture.INFRASTRUCTURE_REVISION)
        report["boots"].append(run_player(root, config, player, sets, 100, pairs[100], offline=True, import_user_root=empty_saves))
        store_root = player.store_root(root, config)
        initial_state = (store_root / "state.json").read_bytes()
        initial_boots = boot_dirs(store_root)
        try:
            publish(feed, archives[101], 101, records[101], pairs, trust, key, output / "feed-101", sets)
            feed.set_corrupt_path(fixture.MARKER)
            try:
                player.run(root, user_args=fixture.GAME_FLAGS)
            except ValueError as error:
                fixture.require(str(error) == "Downloaded artifact differs from signed bytes", str(error))
            else:
                raise ValueError("The Windows player accepted corrupted HTTPS bytes")
            fixture.require((store_root / "state.json").read_bytes() == initial_state and boot_dirs(store_root) == initial_boots,
                            "Corrupt download altered installation state or started a game")
            report["corruptDownloadRejected"] = True
            feed.set_corrupt_path(None)
            confirmed = run_player(root, config, player, sets, 101, pairs[101])
            report["boots"].append(confirmed)
            report["release101Download"] = verify_payload_receipts(feed.requests, 101, records[101])
            marker_route = f"{UPDATES}/versions/101/payload/{fixture.MARKER}"
            fixture.require(sum(item["path"] == marker_route and item["status"] == 200 for item in feed.requests) == 2,
                            "The corrupted file was not downloaded again on retry")

            publish(feed, archives[102], 102, records[102], pairs, trust, key, output / "feed-102", sets)
            report["boots"].append(run_player(root, config, player, sets, 102, pairs[102]))
            report["release102Download"] = verify_payload_receipts(feed.requests, 102, records[102])
            save_path = store_root / "saves" / confirmed["saveGeneration"] / fixture.SAVE
            fixture.require(save_path.read_bytes() == b"101\n", "Fault candidate changed the confirmed save before recovery")
            before = len(feed.requests)
            recovered = run_player(root, config, player, sets, 101, pairs[101])
            report["boots"].append(recovered)
            fixture.require(recovered["saveGeneration"] == confirmed["saveGeneration"] and recovered["saveBytes"] == "101\n",
                            "Recovery used the wrong saved generation")
            fixture.require([item["path"] for item in feed.requests[before:]] == [CURRENT, f"{CURRENT}.sig"],
                            "Recovery re-downloaded a blocked release")
            report.update(status="win64-loopback-feed-passed", preservedSave=True, rejectedRelease=102,
                          confirmedRelease=101)
        finally:
            report["requests"] = feed.requests


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for release in (100, 101, 102):
        parser.add_argument(f"--archive-{release}", type=Path, required=True, help=f"Release {release} UAT Archive/Windows")
    parser.add_argument("--infrastructure", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New local directory for test installation and report")
    args = parser.parse_args()
    report = dict(schemaVersion=1, status="blocked", networkScope="loopback-https", boots=[])
    output_created = False
    try:
        fixture.require(os.name == "nt", "The packaged Win64 smoke requires Windows")
        archives = {release: getattr(args, f"archive_{release}").absolute() for release in (100, 101, 102)}
        resolved = {path.resolve(strict=True) for path in archives.values()}
        infrastructure = args.infrastructure.resolve(strict=True)
        output = args.output.resolve()
        fixture.require(len(resolved) == 3 and all(not output.is_relative_to(path) for path in (*resolved, infrastructure)),
                        "Use three separate archives and a new output outside the input directories")
        output.mkdir()
        output_created = True
        run(archives, infrastructure, output, report)
    except (OSError, ValueError, ImportError, subprocess.SubprocessError) as error:
        report.update(status="blocked", error=str(error))
    rendered = json.dumps(report, indent=2) + "\n"
    if output_created:
        (output / "report.json").write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0 if report["status"] == "win64-loopback-feed-passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
