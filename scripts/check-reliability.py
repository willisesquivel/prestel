#!/usr/bin/env python3
"""Exercise live PTYs and native windows; capture a stuck test host before stopping it."""

import argparse
import datetime
import os
from pathlib import Path
import platform
import plistlib
import signal
import subprocess
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
TEST = "PrestelTests/PrestelTests/sustainedOutputSurvivesLayoutAndSessionChanges()"


def run(command, log, timeout, host):
    with log.open("w") as output:
        process = subprocess.Popen(command, cwd=ROOT, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            processes = subprocess.check_output(
                ["/bin/ps", "-axo", "pid=,comm="], text=True)
            for line in processes.splitlines():
                parts = line.strip().split(None, 1)
                if len(parts) != 2 or parts[1] != str(host):
                    continue
                pid = int(parts[0])
                sample = log.with_name(f"{log.stem}-hang-{pid}.sample.txt")
                subprocess.run(["/usr/bin/sample", str(pid), "3", "-file", str(sample)],
                               stdout=output, stderr=subprocess.STDOUT, timeout=15)
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            print(f"TIMEOUT: diagnostics saved beside {log}", flush=True)
            return 124


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Release")
    parser.add_argument("--runs", type=int, default=5)
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")

    scheme = ET.parse(ROOT / "Prestel.xcodeproj/xcshareddata/xcschemes/Prestel.xcscheme")
    launch = scheme.getroot().find("LaunchAction")
    if (launch.get("buildConfiguration") != "Release"
            or launch.get("selectedDebuggerIdentifier") != ""
            or launch.get("disablePerformanceAntipatternChecker") != "YES"
            or launch.get("disableMainThreadChecker") != "YES"
            or launch.get("selectedLauncherIdentifier") != "Xcode.IDEFoundation.Launcher.PosixSpawn"):
        sys.exit("The everyday Prestel scheme must launch Release without debugger instrumentation")

    derived = ROOT / ".build/reliability" / args.configuration
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    results = derived / f"results-{stamp}"
    results.mkdir(parents=True)
    host = derived / "Build/Products" / args.configuration / "Prestel.app/Contents/MacOS/Prestel"
    base = ["xcodebuild", "-project", "Prestel.xcodeproj", "-scheme", "Prestel",
            "-configuration", args.configuration,
            "-destination", f"platform=macOS,arch={platform.machine()}",
            "-derivedDataPath", str(derived),
            "-clonedSourcePackagesDirPath", str(ROOT / ".build/SourcePackages"),
            "-disableAutomaticPackageResolution", "-skipPackageUpdates",
            "ONLY_ACTIVE_ARCH=YES", "ENABLE_TESTABILITY=YES", "ENABLE_HARDENED_RUNTIME=NO"]
    print(f"Building {args.configuration}; results: {results}", flush=True)
    build_log = results / "build.log"
    code = run(base + ["build-for-testing"], build_log, 600, host)
    if code:
        print(build_log.read_text()[-8000:])
        return code

    products = derived / "Build/Products"
    original = max(products.glob(f"Prestel_*-{platform.machine()}.xctestrun"),
                   key=lambda path: path.stat().st_mtime)
    test_run = plistlib.loads(original.read_bytes())
    for section in ["EnvironmentVariables", "TestingEnvironmentVariables"]:
        variables = test_run["PrestelTests"].get(section, {})
        libraries = variables.get("DYLD_INSERT_LIBRARIES", "").split(":")
        if any("libRPAC" in library for library in libraries):
            sys.exit("Xcode still enabled the Thread Performance Checker in the timing run")
        if "DYLD_INSERT_LIBRARIES" in variables:
            variables["DYLD_INSERT_LIBRARIES"] = ":".join(
                library for library in libraries if "libMainThreadChecker" not in library)
    startup = results / "zsh-startup"
    startup.mkdir()
    (startup / ".zshrc").write_text("PS1='stress % '\nHISTFILE=/dev/null\n")
    test_run["PrestelTests"]["EnvironmentVariables"]["ZDOTDIR"] = str(startup)
    isolated = products / f"Reliability-{stamp}.xctestrun"
    isolated.write_bytes(plistlib.dumps(test_run))

    for iteration in range(1, args.runs + 1):
        log = results / f"run-{iteration}.log"
        print(f"Run {iteration}/{args.runs}: 216,000 output lines and 24 session/layout cycles", flush=True)
        code = run(["xcodebuild", "test-without-building", "-xctestrun", str(isolated),
                          "-destination", f"platform=macOS,arch={platform.machine()}",
                          "-only-testing:" + TEST,
                          "-only-testing:PrestelTests/PrestelTests/narrowSplitKeepsTerminalContentInsideItsCards()",
                          "-only-testing:PrestelTests/PrestelTests/toolbarsFitNarrowPanesAndLongTitles()",
                          "-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "YES",
                          "-maximum-test-execution-time-allowance", "180",
                          "-resultBundlePath", str(results / f"run-{iteration}.xcresult")],
                   log, 240, host)
        if code:
            print(log.read_text()[-8000:])
            return code
        metrics = [line for line in log.read_text().splitlines() if "RELIABILITY rounds=" in line]
        if not metrics:
            sys.exit(f"No stress-test completion metrics in {log}")
        print("\n".join(metrics), flush=True)
    print(f"PASS: {args.runs} fresh test processes; evidence: {results}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
