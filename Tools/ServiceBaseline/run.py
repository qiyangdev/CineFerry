#!/usr/bin/env python3

"""Run the CineFerry service baseline against disposable Jellyfin and Emby servers."""

import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile
from urllib.parse import urlsplit
from uuid import UUID


ROOT = Path(__file__).resolve().parents[2]
TESTS = {"jellyfin": "testJellyfin", "emby": "testEmby"}
PLATFORMS = {
    "ios": ("iOS", "CineFerry", "iphonesimulator", "IOSServiceBaselineTests"),
    "tvos": ("tvOS", "CineFerry tvOS", "appletvsimulator", "TVOSServiceBaselineTests"),
}


def command(arguments, log=None, *, check=True):
    if log is None:
        return subprocess.run(arguments, cwd=ROOT, check=check, capture_output=True, text=True)
    with log.open("x") as stream:
        return subprocess.run(arguments, cwd=ROOT, check=check, stdout=stream, stderr=subprocess.STDOUT)


def load_fixtures(path, services):
    config = json.loads(path.read_text())
    for service in services:
        fixture = config[service]
        url = urlsplit(fixture["url"])
        if url.scheme not in {"http", "https"} or not url.hostname or url.username is not None or url.password is not None:
            raise ValueError(f"{service} must supply a server URL without credentials")
        fixture["simulator"] = str(UUID(fixture["simulator"])).upper()
        for key in ("username", "title"):
            if not isinstance(fixture[key], str) or not fixture[key]:
                raise ValueError(f"{service} must supply {key}")
        if not isinstance(fixture["password"], str):
            raise ValueError(f"{service} must supply a password string")
    if len({config[service]["simulator"] for service in services}) != len(services):
        raise ValueError("Use a separate simulator for each fixture so the app starts signed out")
    return config


def build_test_runner(derived_data, log, target_platform, scheme, sdk):
    command([
        "xcodebuild", "-project", "CineFerry.xcodeproj", "-scheme", scheme,
        "-destination", f"generic/platform={target_platform} Simulator",
        "-derivedDataPath", str(derived_data),
        "-disableAutomaticPackageResolution", "-skipMacroValidation", "-skipPackagePluginValidation",
        f"ARCHS={platform.machine()}", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "build-for-testing",
    ], log)
    products = derived_data / "Build" / "Products"
    runners = sorted(products.glob(f"{scheme}_*{sdk}*.xctestrun"), key=lambda file: file.stat().st_mtime)
    if not runners:
        raise RuntimeError(f"No CineFerry {target_platform} .xctestrun found under {products}")
    return runners[-1]


def configured_runner(template, target, service, fixture):
    with template.open("rb") as source:
        config = plistlib.load(source)
    if "TestConfigurations" in config:
        targets = [
            entry for test_config in config["TestConfigurations"]
            for entry in test_config["TestTargets"]
            if entry.get("BlueprintName") == target or entry.get("TargetName") == target
        ]
    else:
        targets = [config[target]] if target in config else []
    if not targets:
        raise RuntimeError(f"{target} missing in {template.name}")
    environment = {"CINEFERRY_BASELINE_SERVICE": service}
    environment.update({
        f"CINEFERRY_BASELINE_{key.upper()}": fixture[key]
        for key in ("url", "username", "password", "title")
    })
    for entry in targets:
        for field in ("EnvironmentVariables", "TestingEnvironmentVariables"):
            entry.setdefault(field, {}).update(environment)
    # Test product paths in .xctestrun are relative to its file, so install the private copy alongside the template.
    with tempfile.NamedTemporaryFile(dir=template.parent, prefix="CineFerry-Baseline-", suffix=".xctestrun", delete=False) as file:
        plistlib.dump(config, file)
        return Path(file.name)


def run_service(service, fixture, template, results, target, test_class, scenario="playback"):
    device = fixture["simulator"]
    command(["xcrun", "simctl", "bootstatus", device, "-b"], results / f"{service}-boot.log")
    runner = configured_runner(template, target, service, fixture)
    bundle = results / f"{service}.xcresult"
    test = TESTS[service] + ("EpisodeResume" if scenario == "episode-resume" else "")
    try:
        run = command([
            "xcodebuild", "test-without-building", "-xctestrun", str(runner),
            "-destination", f"id={device}", "-resultBundlePath", str(bundle),
            f"-only-testing:{target}/{test_class}/{test}",
            "-parallel-testing-enabled", "NO",
        ], results / f"{service}.log", check=False)
    finally:
        runner.unlink()
    summary = command(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle), "--compact"], check=False)
    if summary.returncode == 0:
        result = json.loads(summary.stdout)
        if run.returncode == 0 and result["passedTests"] == 1 and result["skippedTests"] == 0 and result["failedTests"] == 0:
            print(f"{service}: passed", flush=True)
            return True
    print(f"{service}: failed or skipped; see {results / (service + '.log')}", flush=True)
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    parser.add_argument("--platform", choices=PLATFORMS, default="ios")
    parser.add_argument("--scenario", choices=("playback", "episode-resume"), default="playback")
    parser.add_argument("--derived-data", type=Path, help="Reuse an existing CineFerry DerivedData directory")
    parser.add_argument("--service", choices=TESTS, help="Run a single service while developing a fixture")
    args = parser.parse_args()
    os.umask(0o077)
    results = Path(tempfile.mkdtemp(prefix=f"cineferry-{args.platform}-baseline-")).resolve()
    print(f"Private test results: {results}", flush=True)
    services = (args.service,) if args.service else TESTS
    fixtures = load_fixtures(args.config, services)
    derived_data = args.derived_data.resolve() if args.derived_data else results / "build"
    target_platform, scheme, sdk, test_class = PLATFORMS[args.platform]
    target = f"CineFerry {target_platform} Screenshots"
    template = build_test_runner(derived_data, results / "build.log", target_platform, scheme, sdk)
    outcomes = [run_service(service, fixtures[service], template, results, target, test_class, args.scenario) for service in services]
    return 0 if all(outcomes) else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        # Test inputs contain credentials; logs and errors must never print the configured test environment.
        if isinstance(error, subprocess.CalledProcessError):
            print(f"{error.cmd[0]} exited with status {error.returncode}; see private results.")
        else:
            print(str(error))
        raise SystemExit(1) from None
