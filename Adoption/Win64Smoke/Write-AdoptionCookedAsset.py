"""Author the cooked DataTable used by the disposable Win64 update sample."""

import json
import os
from pathlib import Path

import unreal


ASSET_DIRECTORY = "/Game/Release"
ASSET_NAME = "AdoptionCooked"
ASSET_PATH = f"{ASSET_DIRECTORY}/{ASSET_NAME}.{ASSET_NAME}"
RELEASES = {"100", "101", "102"}
FIXTURE_ROWS = {f"Release{release}" for release in RELEASES}


def write_fixture():
    release = os.environ.get("UE_ADOPTION_FIXTURE_RELEASE")
    if release not in RELEASES or Path(unreal.Paths.get_project_file_path()).name != "SampleGame.uproject":
        raise RuntimeError("Choose release 100, 101 or 102 in the disposable SampleGame project")

    assets = unreal.get_editor_subsystem(unreal.EditorAssetSubsystem)
    row_struct = unreal.TableRowBase.static_struct()
    row_name = f"Release{release}"
    if assets.does_asset_exist(ASSET_PATH):
        table = assets.load_asset(ASSET_PATH)
        if not isinstance(table, unreal.DataTable) or table.get_row_struct() != row_struct:
            raise RuntimeError("Existing asset is not an adoption fixture DataTable")
        rows = table.get_row_names()
        if len(rows) != 1 or str(rows[0]) not in FIXTURE_ROWS:
            raise RuntimeError("Existing DataTable does not contain an adoption fixture row")
    else:
        factory = unreal.DataTableFactory()
        factory.set_editor_property("struct", row_struct)
        table = unreal.AssetToolsHelpers.get_asset_tools().create_asset(
            ASSET_NAME, ASSET_DIRECTORY, unreal.DataTable, factory)
        if not isinstance(table, unreal.DataTable):
            raise RuntimeError("Could not create the adoption DataTable")

    if not unreal.DataTableFunctionLibrary.fill_data_table_from_json_string(
            table, json.dumps([{"Name": row_name}]), row_struct):
        raise RuntimeError("Could not populate the adoption DataTable")
    if [str(name) for name in table.get_row_names()] != [row_name]:
        raise RuntimeError("The adoption DataTable does not contain its expected row")
    if not assets.save_loaded_asset(table, False):
        raise RuntimeError("Could not save the adoption DataTable")
    unreal.log(f"UE_ADOPTION_COOKED_ASSET_WRITTEN release={release} asset={ASSET_PATH}")


write_fixture()
