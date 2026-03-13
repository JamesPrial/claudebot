"""Ensure the current process has docker group access."""
import getpass
import grp
import os
import shlex
import sys


def ensure_docker_group() -> None:
    """Re-exec under `sg docker` if we lack docker socket access but are in the group."""
    sock = "/var/run/docker.sock"
    if not os.path.exists(sock) or os.access(sock, os.W_OK):
        return

    # Already retried — bail out with a clear error
    if os.environ.get("_CLAUDEBOT_SG_RETRY"):
        print("Error: Cannot access Docker socket even after sg docker.", file=sys.stderr)
        print("  Check: ls -la /var/run/docker.sock && groups", file=sys.stderr)
        sys.exit(1)

    # Only re-exec if the user is actually in the docker group (per /etc/group)
    try:
        docker_grp = grp.getgrnam("docker")
        if getpass.getuser() not in docker_grp.gr_mem:
            return  # user not in docker group; sg won't help
    except KeyError:
        return  # no docker group on this system

    os.environ["_CLAUDEBOT_SG_RETRY"] = "1"
    argv_str = " ".join(shlex.quote(a) for a in sys.argv)
    os.execvp("sg", ["sg", "docker", "-c", f"{shlex.quote(sys.executable)} {argv_str}"])
