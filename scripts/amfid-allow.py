#!/Library/Developer/CommandLineTools/usr/bin/python3 -I

# from https://gist.github.com/zhaofengli/1df11ae3f0dd4e2c872a12ef849f7371
# must be run with CommandLineTools Python to have lldb available

README = """
# amfid-allow
This script hooks into macOS amfid to grant restricted entitlements
to selected executables. Tested on macOS 15.4.
## Prerequisites
Only disabling Debugging Restrictions (`ALLOW_TASK_FOR_PID`) is
required and other SIP restrictions can be left enabled:
    csrutil enable --without debug
As you will see, having just unrestricted debug access is quite
dangerous and makes root very powerful again: Malicious programs
running as root can effectively gain arbitrary entitlements by
debugging amfid. Consider restricting debugging access via some
other means.
## Usage
To bypass validation for "/Users/yourname/a.out" once:
    sudo ./amfid-allow.py --path "/Users/yourname/a.out"
To bypass validation for the binary with CDHash "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" once:
    sudo ./amfid-allow.py --cdhash "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
To customize the checks, edit the `custom_checks` function then pass `--use-custom-checks`:
    sudo ./amfid-allow.py --use-custom-checks
By default, the script will detach from amfid after it overrides the first
verdict. Pass `--run-forever` to keep it attached.
"""


def custom_checks(result) -> bool:
    # Add your custom checks here. Example:
    #
    # if result["path"].startswith("/some/path"):
    #     return True
    #
    # See `dump_validator_state` below for other keys you can use.

    # The result is OR'd with the original verdict and the
    # verdicts from rules passed on the command-line.
    return False


LLDB = "/Library/Developer/CommandLineTools/usr/bin/lldb"
AMFID = "/usr/libexec/amfid"

import argparse
import logging
import subprocess
import sys
import threading
from pprint import pprint

lldb_py = subprocess.run(
    [LLDB, "--python-path"], check=True, encoding="utf-8", capture_output=True
).stdout
if lldb_py:
    sys.path.append(lldb_py.strip())

import lldb


def handle_validate(*, target, thread, args) -> bool:
    if "arm64" in target.GetTriple():
        ret_reg = self_reg = "x0"
    else:
        ret_reg = "rax"
        self_reg = "rdi"

    logging.info("Handling validation")
    frame = thread.frames[0]
    validator = frame.reg[self_reg].value

    thread.StepOut()
    thread = get_stopped_thread(process, lldb.eStopReasonPlanComplete)
    if not thread:
        raise RuntimeError("Failed to step out")

    frame = thread.frames[0]
    ret = frame.reg[ret_reg]

    state = dump_validator_state(target=target, validator=validator)
    print("Original validation result:")
    pprint(state)

    logging.info(f"Original verdict: {state['is_valid']}")
    if state["is_valid"]:
        return True

    allow = False

    if args.path:
        allowed_by_path = state["path"] in args.path
        allow |= allowed_by_path
        logging.info(f"Allowed by --path: {allowed_by_path}")

    if args.cdhash:
        allowed_by_cdhash = state["cdhash"] in args.cdhash
        allow |= allowed_by_cdhash
        logging.info(f"Allowed by --cdhash: {allowed_by_cdhash}")

    if args.use_custom_checks:
        allowed_by_custom_checks = custom_checks(state)
        allow |= allowed_by_custom_checks
        logging.info(f"Allowed by custom_checks: {allowed_by_custom_checks}")

    logging.info(f"New verdict: {allow}")
    if not allow:
        return True

    logging.info("Bypassing validation")
    target.EvaluateExpression(f'(void)NSLog(@"[amfid-allow] Overriding verdict")')
    ret.SetValueFromCString("1")

    return args.run_forever


def dump_validator_state(*, target, validator):
    is_valid = bool(
        target.EvaluateExpression(f"(BOOL)[(id){validator} isValid]").unsigned
    )
    are_entitlements_validated = bool(
        target.EvaluateExpression(
            f"(BOOL)[(id){validator} areEntitlementsValidated]"
        ).unsigned
    )

    path = target.EvaluateExpression(
        f"(NSURL*)[(id){validator} codePath]"
    ).GetObjectDescription()
    if not path.startswith("file://"):
        raise ValueError(f"Only file:// code paths are supported (got {path})")
    path = path[len("file://") :]

    # <aaaaaaaa aaaaaaaa aaaaaaaa aaaaaaaa aaaaaaaa>
    cdhash = target.EvaluateExpression(
        "(NSData*)[(id){} cdhashAsData]".format(validator)
    )
    cdhash = cdhash.GetObjectDescription()[1:-1].replace(" ", "")

    # Maybe invalid - Don't rely on them!
    identifier = target.EvaluateExpression(
        f"(NSString*)[(id){validator} signingIdentifier]"
    ).GetObjectDescription()
    team_identifier = target.EvaluateExpression(
        f"(NSString*)[(id){validator} teamIdentifier]"
    ).GetObjectDescription()

    return {
        "is_valid": is_valid,
        "are_entitlements_validated": are_entitlements_validated,
        "path": path,
        "cdhash": cdhash,
        "unverified": {
            "identifier": identifier,
            "team_identifier": team_identifier,
        },
    }


def get_stopped_thread(process, reason):
    for t in process:
        if t.GetStopReason() == reason:
            return t
    return None


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)

    parser = argparse.ArgumentParser(
        prog="amfid-allow",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="Grant restricted entitlements to selected executables.",
        epilog="\n" + README,
    )
    parser.add_argument(
        "--path",
        help="the path of an executable to allow (can be specified multiple times)",
        action="append",
        default=[],
    )
    parser.add_argument(
        "--cdhash",
        help="the CDHash of an executable to allow (can be specified multiple times)",
        action="append",
        default=[],
    )
    parser.add_argument(
        "--use-custom-checks",
        help="use the custom checks defined in the script",
        action="store_true",
        default=False,
    )
    parser.add_argument(
        "--run-forever",
        help="remain attached to amfid after the first bypass",
        action="store_true",
        default=False,
    )

    if len(sys.argv) == 1:
        parser.print_help(sys.stderr)
        sys.exit(1)

    args = parser.parse_args()

    if not args.run_forever:
        logging.info(
            "Quitting after one verdict is overridden. Pass --run-forever to keep the script attached to amfid."
        )

    debugger = lldb.SBDebugger.Create()
    debugger.SetAsync(False)

    logging.info("Attaching to amfid...")
    target = debugger.CreateTarget("")

    error = lldb.SBError()
    process = target.AttachToProcessWithName(
        debugger.GetListener(), AMFID, False, error
    )
    if not process:
        logging.error("Failed to attach to amfid: %s", error)
        sys.exit(1)

    validate_bp = target.BreakpointCreateByName(
        "-[AMFIPathValidator_macos validateWithError:]"
    )
    if len(validate_bp.locations) == 0:
        raise RuntimeError(
            "No location found for breakpoint - This version of macOS isn't supported"
        )

    def listener():
        logging.info("Start your program now")
        while True:
            process.Continue()
            if process.state not in [
                lldb.eStateStopped,
                lldb.eStateRunning,
                lldb.eStateSuspended,
            ]:
                raise RuntimeError(
                    f"Bad process state {process.state} (we are probably disconnected)"
                )

            if thread := get_stopped_thread(process, lldb.eStopReasonBreakpoint):
                stop_reason_data = [
                    thread.GetStopReasonDataAtIndex(idx)
                    for idx in range(thread.GetStopReasonDataCount())
                ]
                breakpoint_id = stop_reason_data[0]

                if breakpoint_id == validate_bp.GetID():
                    if not handle_validate(target=target, thread=thread, args=args):
                        break
                else:
                    logging.warning("Unknown breakpoint")

    thread = threading.Thread(target=listener)
    thread.daemon = True
    thread.start()
    thread.join()

    logging.info("Detaching from amfid")
    process.Detach()
