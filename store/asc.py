# /// script
# requires-python = ">=3.12"
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""Minimal App Store Connect API client for Alai's store listing.

Credentials come from ~/.appstoreconnect/alai.env (ASC_KEY_ID, ASC_ISSUER_ID) and the key at
~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8.
"""
import hashlib
import os
import sys
import time
from pathlib import Path

import jwt
import requests

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "me.4vr.alai"


def _load_env():
    env = Path.home() / ".appstoreconnect" / "alai.env"
    for line in env.read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip())


def token() -> str:
    _load_env()
    key_id = os.environ["ASC_KEY_ID"]
    private_key = (Path.home() / ".appstoreconnect" / "private_keys" / f"AuthKey_{key_id}.p8").read_text()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"},
        private_key,
        algorithm="ES256",
        headers={"kid": key_id},
    )


class Client:
    def __init__(self):
        self.session = requests.Session()
        self.session.headers["Authorization"] = f"Bearer {token()}"

    def request(self, method, path, **kwargs):
        url = path if path.startswith("http") else API + path
        response = self.session.request(method, url, **kwargs)
        if response.status_code >= 400:
            sys.exit(f"{method} {path} failed with {response.status_code}: {response.text}")
        return response.json() if response.content else None

    def get(self, path, **params):
        return self.request("GET", path, params=params)

    def post(self, path, data):
        return self.request("POST", path, json={"data": data})

    def patch(self, path, data):
        return self.request("PATCH", path, json={"data": data})

    def app(self):
        apps = self.get("/apps", **{"filter[bundleId]": BUNDLE_ID})["data"]
        if not apps:
            sys.exit(f"No App Store Connect app with bundle ID {BUNDLE_ID}")
        return apps[0]


STORE = Path(__file__).parent
LOCALE = "en-US"
SCREENSHOT_SETS = {"iphone-6.9": "APP_IPHONE_67", "watch": "APP_WATCH_SERIES_10"}


def read(name):
    return (STORE / LOCALE / name).read_text().strip()


def urls():
    return dict(line.split("=", 1) for line in (STORE / "urls.txt").read_text().split())


def editable_version(client, app):
    versions = client.get(f"/apps/{app['id']}/appStoreVersions", **{"filter[appStoreState]": "PREPARE_FOR_SUBMISSION,DEVELOPER_REJECTED,REJECTED,METADATA_REJECTED"})["data"]
    if not versions:
        sys.exit("No editable App Store version; create one in App Store Connect first")
    return versions[0]


def push_app_info(client, app):
    info = client.get(f"/apps/{app['id']}/appInfos")["data"][0]
    client.patch(f"/appInfos/{info['id']}", {
        "type": "appInfos", "id": info["id"],
        "relationships": {
            "primaryCategory": {"data": {"type": "appCategories", "id": "UTILITIES"}},
            "secondaryCategory": {"data": {"type": "appCategories", "id": "DEVELOPER_TOOLS"}},
        },
    })
    localization = next(l for l in client.get(f"/appInfos/{info['id']}/appInfoLocalizations")["data"] if l["attributes"]["locale"] == LOCALE)
    client.patch(f"/appInfoLocalizations/{localization['id']}", {
        "type": "appInfoLocalizations", "id": localization["id"],
        "attributes": {"name": read("name.txt"), "subtitle": read("subtitle.txt"), "privacyPolicyUrl": urls()["privacy_url"]},
    })
    print("app info: name, subtitle, privacy URL, categories")
    return info


def push_age_rating(client, info, answers):
    declaration = client.get(f"/appInfos/{info['id']}/ageRatingDeclaration")["data"]
    client.patch(f"/ageRatingDeclarations/{declaration['id']}", {"type": "ageRatingDeclarations", "id": declaration["id"], "attributes": answers})
    print("age rating declaration")


def push_version(client, version):
    client.patch(f"/appStoreVersions/{version['id']}", {
        "type": "appStoreVersions", "id": version["id"],
        "attributes": {"copyright": read("copyright.txt")},
    })
    localization = next(l for l in client.get(f"/appStoreVersions/{version['id']}/appStoreVersionLocalizations")["data"] if l["attributes"]["locale"] == LOCALE)
    attributes = {
        "description": read("description.txt"),
        "keywords": read("keywords.txt"),
        "promotionalText": read("promotional_text.txt"),
        "supportUrl": urls()["support_url"],
        "marketingUrl": urls()["marketing_url"],
    }
    client.patch(f"/appStoreVersionLocalizations/{localization['id']}", {"type": "appStoreVersionLocalizations", "id": localization["id"], "attributes": attributes})
    print("version: copyright, description, keywords, promotional text, URLs")
    return localization


def upload_screenshot(client, set_id, path):
    data = path.read_bytes()
    created = client.post("/appScreenshots", {
        "type": "appScreenshots",
        "attributes": {"fileName": path.name, "fileSize": len(data)},
        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}},
    })["data"]
    for operation in created["attributes"]["uploadOperations"]:
        chunk = data[operation["offset"]:operation["offset"] + operation["length"]]
        headers = {h["name"]: h["value"] for h in operation["requestHeaders"]}
        response = requests.request(operation["method"], operation["url"], data=chunk, headers=headers)
        response.raise_for_status()
    client.patch(f"/appScreenshots/{created['id']}", {
        "type": "appScreenshots", "id": created["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()},
    })


def push_screenshots(client, localization):
    existing = {s["attributes"]["screenshotDisplayType"]: s for s in client.get(f"/appStoreVersionLocalizations/{localization['id']}/appScreenshotSets")["data"]}
    for folder, display_type in SCREENSHOT_SETS.items():
        files = sorted((STORE / "screenshots" / folder).glob("*.png"))
        if not files:
            continue
        if display_type in existing:
            set_id = existing[display_type]["id"]
            for old in client.get(f"/appScreenshotSets/{set_id}/appScreenshots")["data"]:
                client.request("DELETE", f"/appScreenshots/{old['id']}")
        else:
            set_id = client.post("/appScreenshotSets", {
                "type": "appScreenshotSets",
                "attributes": {"screenshotDisplayType": display_type},
                "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": localization["id"]}}},
            })["data"]["id"]
        for path in files:
            upload_screenshot(client, set_id, path)
        print(f"screenshots: {len(files)} × {display_type}")


def push_review_details(client, version):
    contact_file = Path.home() / ".appstoreconnect" / "alai-review.env"
    if not contact_file.exists():
        print(f"review details: skipped, {contact_file} not found")
        return
    contact = dict(line.split("=", 1) for line in contact_file.read_text().splitlines() if "=" in line)
    attributes = {
        "contactFirstName": contact["first_name"], "contactLastName": contact["last_name"],
        "contactPhone": contact["phone"], "contactEmail": contact["email"],
        "demoAccountRequired": True, "demoAccountName": contact["demo_user"], "demoAccountPassword": contact["demo_password"],
        "notes": (STORE / "review_notes.txt").read_text().strip(),
    }
    current = client.get(f"/appStoreVersions/{version['id']}/appStoreReviewDetail").get("data")
    if current:
        client.patch(f"/appStoreReviewDetails/{current['id']}", {"type": "appStoreReviewDetails", "id": current["id"], "attributes": attributes})
    else:
        client.post("/appStoreReviewDetails", {
            "type": "appStoreReviewDetails", "attributes": attributes,
            "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}},
        })
    print("review details: contact, demo account, notes")


def attach_build(client, app, version, build_number):
    builds = client.get("/builds", **{"filter[app]": app["id"], "filter[version]": build_number})["data"]
    if not builds or builds[0]["attributes"]["processingState"] != "VALID":
        sys.exit(f"Build {build_number} is not processed yet")
    client.request("PATCH", f"/appStoreVersions/{version['id']}/relationships/build", json={"data": {"type": "builds", "id": builds[0]["id"]}})
    print(f"build {build_number} attached to version {version['attributes']['versionString']}")


AGE_RATING = {
    # Content descriptions: none of these appear in the app
    **{key: "NONE" for key in [
        "alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated", "gunsOrOtherWeapons",
        "horrorOrFearThemes", "matureOrSuggestiveThemes", "medicalOrTreatmentInformation", "profanityOrCrudeHumor",
        "sexualContentGraphicAndNudity", "sexualContentOrNudity", "violenceCartoonOrFantasy", "violenceRealistic",
        "violenceRealisticProlongedGraphicOrSadistic",
    ]},
    # Capabilities: links open in Safari, not an in-app browser; no ads, gambling or age gating. Messages
    # come from the user's own servers and services, not from other people, so it is neither chat nor UGC.
    **{key: False for key in [
        "advertising", "gambling", "healthOrWellnessTopics", "lootBox", "parentalControls", "ageAssurance",
        "unrestrictedWebAccess", "socialMedia", "messagingAndChat", "userGeneratedContent",
    ]},
}


def listing(build_number=None):
    """Pushes the store listing; with a build number, also attaches that build to the version."""
    client = Client()
    app = client.app()
    version = editable_version(client, app)
    info = push_app_info(client, app)
    push_age_rating(client, info, AGE_RATING)
    localization = push_version(client, version)
    push_screenshots(client, localization)
    push_review_details(client, version)
    if build_number:
        attach_build(client, app, version, build_number)


def status():
    client = Client()
    app = client.app()
    print(app["id"], app["attributes"]["name"], app["attributes"]["bundleId"])
    versions = client.get(f"/apps/{app['id']}/appStoreVersions")["data"]
    for version in versions:
        print("version", version["attributes"]["versionString"], version["attributes"]["appStoreState"], version["id"])
    builds = client.get("/builds", **{"filter[app]": app["id"], "sort": "-uploadedDate", "limit": 5})["data"]
    for build in builds:
        print("build", build["attributes"]["version"], build["attributes"]["processingState"])


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "status"
    if command == "listing":
        listing(sys.argv[2] if len(sys.argv) > 2 else None)
    else:
        status()
