#!/usr/bin/env python3
"""Integration check for macOS: requires a debug build and remote tmux 3.2+.

Uses an ephemeral loopback sshd, generated keys, isolated tmux socket directory
and disposable sessions. It does not use the user's SSH config or sessions.
"""
import tempfile,pathlib,subprocess,socket,os,json,pty,fcntl,termios,struct,select,time,signal,uuid,shutil,sys
os.chdir(pathlib.Path(__file__).resolve().parent.parent)
root=pathlib.Path(tempfile.mkdtemp(prefix='bmux-ssh-fixture-',dir='/tmp'))
encrypted='--encrypted-key' in sys.argv
server=None; queryargs=[]; launchers=[]; session_name='fixture-'+str(uuid.uuid4()); sshargs=[]
def remote(command):
    result=subprocess.run(['/usr/bin/ssh',*(queryargs or sshargs),'PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"; export PATH; '+command],capture_output=True,text=True,timeout=12)
    if result.returncode: raise RuntimeError(f'SSH {result.returncode}: {result.stderr}')
    return result.stdout.strip()
def launch():
    pid,fd=pty.fork()
    if pid==0:
        env=dict(os.environ,BMUX_TS=str(root/'transcript'),BMUX_INNER='ssh',BMUX_REMOTE_SESSION=json.dumps({'name':session_name,'sshArguments':sshargs,'remoteCommand':['/bin/sh']}),BMUX_CLOSE_FILE=str(root/'close'),BMUX_CLEANUP_FILE=str(root/'cleanup.json'),BMUX_CLOSE_DIRECTORY=str(root))
        os.execve(str(pathlib.Path('.build/debug/bmux-launch').resolve()),['bmux-launch','fixture'],env)
    fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',24,80,0,0))
    launchers.append((pid,fd))
    if encrypted:
        read_until(fd,b'Enter passphrase')
        os.write(fd,b'fixture-passphrase\r')
    return pid,fd
buffers={}
def read_until(fd,needle,seconds=10):
    end=time.monotonic()+seconds;data=buffers.get(fd,b'')
    while needle not in data and time.monotonic()<end:
        if select.select([fd],[],[],.1)[0]:
            try: data+=os.read(fd,65536)
            except OSError: break
    buffers[fd]=data
    if needle not in data: raise AssertionError(f'missing {needle!r}; tail={data[-1000:]!r}')
    return data
def wait_remote(format,value,seconds=5):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        if launchers:
            fd=launchers[-1][1]
            while select.select([fd],[],[],0)[0]:
                try: buffers[fd]=buffers.get(fd,b'')+os.read(fd,65536)
                except OSError: break
        actual=remote(f"tmux -L bmux-v1 display-message -p -t '={session_name}:' '{format}'")
        if actual==value:return
        time.sleep(.1)
    raise AssertionError(f'remote state {format}: {actual!r}, expected {value!r}')
try:
    (root/'remote').mkdir(mode=0o700)
    for key in ('host','client','query'):
        subprocess.run(['/usr/bin/ssh-keygen','-q','-t','ed25519','-N','fixture-passphrase' if encrypted and key=='client' else '', '-f',str(root/key)],check=True)
    (root/'authorized_keys').write_text((root/'client.pub').read_text()+(root/'query.pub').read_text())
    sock=socket.socket();sock.bind(('127.0.0.1',0));port=sock.getsockname()[1];sock.close()
    (root/'sshd_config').write_text(f'''Port {port}\nListenAddress 127.0.0.1\nHostKey {root}/host\nPidFile {root}/pid\nAuthorizedKeysFile {root}/authorized_keys\nStrictModes no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nUseDNS no\nLogLevel ERROR\nAcceptEnv TMUX_TMPDIR\nAllowUsers {os.environ['USER']}\n''')
    log=open(root/'sshd.log','wb')
    server=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(root/'sshd_config')],stderr=log)
    sshargs=['-F','/dev/null','-p',str(port),'-i',str(root/'client'),'-o','StrictHostKeyChecking=accept-new','-o',f'UserKnownHostsFile={root}/known_hosts','-o',f'SetEnv=TMUX_TMPDIR={root}/remote','127.0.0.1']
    queryargs=[str(root/'query') if x==str(root/'client') else x for x in sshargs]
    time.sleep(.2)
    assert remote('echo transport-ready')=='transport-ready'
    pid,fd=launch();read_until(fd,b'\x1b[3J')
    shell_pid=remote(f"tmux -L bmux-v1 display-message -p -t '={session_name}:' '#{{pane_pid}}'")
    os.write(fd,b"for i in $(seq 1 100); do printf 'line-%s\\n' \"$i\"; done\r")
    read_until(fd,b'line-100\r\n')
    # Drop the local transport without touching the server or remote pane.
    child=int(subprocess.check_output(['pgrep','-P',str(pid)],text=True).split()[0])
    buffers[fd]=b''
    os.kill(child,signal.SIGKILL)
    read_until(fd,b'SSH disconnected')
    if encrypted:
        read_until(fd,b'Enter passphrase')
        os.write(fd,b'fixture-passphrase\r')
    read_until(fd,b'\x1bc',seconds=12)
    time.sleep(2)
    assert remote(f"tmux -L bmux-v1 display-message -p -t '={session_name}:' '#{{pane_pid}}'")==shell_pid
    os.write(fd,b"printf 'after-drop\\n'\r");read_until(fd,b'after-drop\r\n')
    # Exercise a real alternate-screen app and resize it through the helper.
    (root/'vim.txt').write_text('vim-persistence-fixture\nsecond line\n')
    os.write(fd,f'vim -u NONE -i NONE {root}/vim.txt\r'.encode())
    wait_remote('#{alternate_on}','1')
    read_until(fd,b'vim-persistence-fixture')
    fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',31,105,0,0));os.kill(pid,signal.SIGWINCH)
    wait_remote('#{pane_width},#{pane_height}','105,31')
    # Closing outer PTY simulates quitting bmux. Reopening gets same shell/vim.
    os.close(fd);os.waitpid(pid,0);launchers.remove((pid,fd));buffers.pop(fd,None)
    pid,fd=launch();data=read_until(fd,b'vim-persistence-fixture')
    assert b'\x1b[?1049h' in data
    wait_remote('#{alternate_on}','1')
    assert remote(f"tmux -L bmux-v1 display-message -p -t '={session_name}:' '#{{pane_pid}}'")==shell_pid
    os.write(fd,b'\x1b:q!\r');wait_remote('#{alternate_on}','0')
    # A saved close request uses this authenticated connection, so it also
    # works on password-only hosts where BatchMode cleanup cannot log in.
    obsolete='obsolete-'+str(uuid.uuid4())
    remote(f"tmux -L bmux-v1 new-session -d -s '{obsolete}' /bin/sh")
    (root/'cleanup.json').write_text(json.dumps([{'name':obsolete,'sshArguments':sshargs,'remoteCommand':[]}]))
    end=time.monotonic()+8
    while not (root/('close-'+obsolete+'.done')).exists() and time.monotonic()<end:time.sleep(.1)
    assert (root/('close-'+obsolete+'.done')).exists(),'queued sibling close was not acknowledged'
    assert remote(f"tmux -L bmux-v1 has-session -t '={obsolete}' 2>/dev/null; echo $?")=='1'
    # An explicit close uses the authenticated control channel (no second login).
    (root/'close').touch()
    end=time.monotonic()+5
    while not (root/'close.done').exists() and time.monotonic()<end:time.sleep(.1)
    assert (root/'close.done').exists(),'close was not acknowledged'
    assert remote(f"tmux -L bmux-v1 has-session -t '={session_name}' 2>/dev/null; echo $?")=='1'
    print(('Encrypted-key authentication: ' if encrypted else '')+'PASS: real SSH + bmux-launch; automatic reconnect; same remote PID; vim restore; 105x31 resize; quit/reopen; queued sibling cleanup; explicit remote close')
finally:
    for pid,fd in launchers:
        try:os.close(fd)
        except OSError:pass
        try:os.kill(pid,signal.SIGTERM);os.waitpid(pid,0)
        except (ProcessLookupError,ChildProcessError):pass
    if server:
        try:
            if sshargs:remote(f"tmux -L bmux-v1 kill-session -t '={session_name}' 2>/dev/null || true")
        except Exception:pass
        server.terminate();server.wait(timeout=5)
    shutil.rmtree(root)
