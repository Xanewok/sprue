# Runs argv on a pseudo-terminal that types $PTY_PASSWORD at a keystore prompt and the next of the
# comma-separated $PTY_ANSWER at each `Type yes: `, where ^C is Ctrl-C. $PTY_HOOK runs while a question waits.
import os, pty, subprocess, sys
answers, password = os.environ["PTY_ANSWER"].split(","), os.environ["PTY_PASSWORD"]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
seen = b""
while True:
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    sys.stdout.buffer.write(data); sys.stdout.flush()
    seen += data
    for prompt, reply in ((b"assword", password), (b"Type yes: ", answers[0])):
        if prompt in seen:
            if prompt == b"Type yes: ":
                if len(answers) > 1:
                    answers.pop(0)
                if os.environ.get("PTY_HOOK"):
                    subprocess.run(os.environ["PTY_HOOK"], shell=True, check=True, stdout=subprocess.DEVNULL)
            os.write(fd, b"\x03" if reply == "^C" else reply.encode() + b"\n"); seen = b""
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
