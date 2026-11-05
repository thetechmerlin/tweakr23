#!/usr/bin/env python3
# =====================================================================
#  Tweakr23 engine for Ubuntu / Debian-based Linux (GNOME-first)
#  https://github.com/thetechmerlin/Tweakr23  -  MIT License  -  (c) 2026 Tech Merlin
#
#  Python 3 standard library only. Runs as YOUR user; system-level tasks
#  use `sudo -n` (the launcher asks for your password once up front).
#  Serves ../ui/index.html on http://127.0.0.1:<random port>/ with a
#  per-session token. Nothing is sent anywhere except driver/firmware
#  checks (ubuntu-drivers / fwupd) when you press that button.
# =====================================================================
import configparser, datetime, glob, json, os, pwd, re, secrets, shutil, signal
import socket, subprocess, sys, threading, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.path.expanduser('~')
ROOT = os.path.dirname(os.path.abspath(__file__))
TOKEN = secrets.token_hex(16)
UID = os.getuid()
STATE_DIR = os.path.join(os.environ.get('XDG_CONFIG_HOME', os.path.join(HOME, '.config')), 'tweakr23')
LAST_PING = [time.time()]
IDLE_EXIT = 300
QUIT = threading.Event()


# ---------------------------------------------------------------- helpers
def sh(cmd, timeout=60, sudo=False, ok_codes=(0,)):
    """Run a command, return (code, stdout). Never raises."""
    if isinstance(cmd, str):
        cmd = ['bash', '-c', cmd]
    if sudo and UID != 0:
        cmd = ['sudo', '-n'] + cmd
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or '') + ('' if p.returncode in ok_codes else (p.stderr or ''))
    except FileNotFoundError:
        return 127, ''
    except subprocess.TimeoutExpired:
        return 124, 'timed out'


def has(cmd):
    return shutil.which(cmd) is not None


def need_sudo():
    if UID == 0:
        return True
    return sh(['sudo', '-n', 'true'], timeout=5)[0] == 0


def sudo_or_raise():
    if not need_sudo():
        raise RuntimeError('Needs admin rights - start Tweakr23 with the launcher (tweakr23.sh) and enter your password.')


def read(path, default=''):
    try:
        with open(path, encoding='utf-8', errors='replace') as fh:
            return fh.read()
    except OSError:
        return default


def human(n):
    return f'{n / 1048576:.1f} MB'


def files_under(path, min_age_h=0, exclude=()):
    """Walk a folder without following symlinks; yield (path, size, mtime)."""
    if not os.path.isdir(path):
        return
    cut = time.time() - min_age_h * 3600
    for root, dirs, files in os.walk(path, followlinks=False):
        if exclude:
            dirs[:] = [d for d in dirs if os.path.join(root, d) not in exclude]
        for fn in files:
            fp = os.path.join(root, fn)
            try:
                st = os.lstat(fp)
            except OSError:
                continue
            if not min_age_h or st.st_mtime < cut:
                yield fp, st.st_size, st.st_mtime


def remove_empty_dirs(path):
    for root, dirs, _ in os.walk(path, topdown=False, followlinks=False):
        for d in dirs:
            try:
                os.rmdir(os.path.join(root, d))
            except OSError:
                pass


def mem_info():
    m = {}
    for line in read('/proc/meminfo').splitlines():
        k, _, v = line.partition(':')
        m[k] = int(v.split()[0]) * 1024 if v.split() else 0
    return {'total': m.get('MemTotal', 0), 'free': m.get('MemAvailable', m.get('MemFree', 0))}


def terminal(title, command):
    """Run a long job in a visible terminal window so the panel stays responsive."""
    script = f'echo -e "\\e]0;{title}\\a"; {command}; echo; echo "Done. You can close this window."; read -r _'
    for term, args in (('ptyxis', ['--']), ('gnome-terminal', ['--']), ('kgx', ['-e']), ('konsole', ['-e']),
                       ('xfce4-terminal', ['-x']), ('mate-terminal', ['-x']), ('tilix', ['-e']), ('x-terminal-emulator', ['-e'])):
        if has(term):
            subprocess.Popen([term] + args + ['bash', '-c', script], start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
    raise RuntimeError('No terminal app found to run this in.')


def launch(*cmd):
    subprocess.Popen(list(cmd), start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def pid_alive(pid):
    return os.path.exists(f'/proc/{pid}')


def lock_alive(path):
    """Chromium SingletonLock / Firefox lock are symlinks to 'host-PID' / 'host:+PID'."""
    if os.path.islink(path):
        m = re.search(r'(\d+)$', os.readlink(path))
        return bool(m and pid_alive(m.group(1)))
    return os.path.exists(path)


# ---------------------------------------------------------------- desktop files
def parse_desktop(path):
    cp = configparser.RawConfigParser(strict=False, interpolation=None)
    cp.optionxform = str
    try:
        cp.read(path, encoding='utf-8')
        return dict(cp['Desktop Entry']) if cp.has_section('Desktop Entry') else {}
    except Exception:
        return {}


def edit_desktop(path, changes):
    """Set keys in the [Desktop Entry] section, keeping everything else byte-for-byte."""
    lines = read(path).splitlines()
    out, in_sec, done = [], False, set()
    for ln in lines:
        s = ln.strip()
        if s.startswith('['):
            if in_sec:
                out += [f'{k}={v}' for k, v in changes.items() if k not in done]
                done.update(changes)
            in_sec = (s == '[Desktop Entry]')
        elif in_sec and '=' in ln:
            k = ln.split('=', 1)[0].strip()
            if k in changes:
                out.append(f'{k}={changes[k]}')
                done.add(k)
                continue
        out.append(ln)
    if in_sec:
        out += [f'{k}={v}' for k, v in changes.items() if k not in done]
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(out) + '\n')


def exec_binary(exec_line):
    try:
        import shlex
        parts = shlex.split(exec_line)
    except Exception:
        parts = exec_line.split()
    while parts and (parts[0] == 'env' or re.match(r'^\w+=', parts[0])):
        parts.pop(0)
    return parts[0] if parts else ''


# ---------------------------------------------------------------- startup
STARTUP_RULES = [
    ('keep', r'polkit|gnome-keyring|ssh-agent|gpg-agent|xdg-user-dirs|at-spi|ibus|fcitx|im-launch|pipewire|pulseaudio|wireplumber|org\.gnome\.|gsd-|snap-userd|spice-vdagent|geoclue', 'Part of your desktop session. Keep it.'),
    ('keep', r'nm-applet|network-manager|blueman|bluetooth', 'Network/Bluetooth tray. Keep it if you use the tray icon.'),
    ('keep', r'bitwarden|1password|keepass|protonpass', 'Password manager. Keep it if you want autofill ready at login.'),
    ('keep', r'wacom|opentabletdriver|xp-pen|huion', 'Drawing tablet driver. Keep it for pen pressure and buttons.'),
    ('optional', r'dropbox|nextcloud|syncthing|megasync|insync|pcloud|onedrive|rclone', 'Cloud sync. Keep it if you want files syncing in the background.'),
    ('optional', r'solaar|piper|openrgb|ckb-next|polychromatic', 'Peripheral software. Keep it if you use custom buttons or RGB.'),
    ('optional', r'update-notifier', 'Ubuntu update reminders. Keep it unless you update another way.'),
    ('optional', r'evolution-alarm|evolution-data', 'Calendar reminders. Turn off if you do not use Evolution/GNOME Calendar.'),
    ('optional', r'cups|printer|print-applet|system-config-printer', 'Printing. Turn off if you never print.'),
    ('optional', r'avahi', 'Network discovery (printers, shares). Turn off if you do not need it.'),
    ('optional', r'modemmanager', 'Mobile broadband modems. Turn off unless you use a 4G/5G modem.'),
    ('disable', r'whoopsie|apport|kerneloops', 'Crash reporting to Ubuntu. Not needed to run your PC.'),
    ('disable', r'spotify|discord|telegram|signal|whatsapp|slack|teams|zoom|skype|element', 'Chat/music app. Slows login; open it when you want it.'),
    ('disable', r'steam|lutris|heroic|itch', 'Game launcher. Opens fine when you start a game.'),
    ('disable', r'tracker-miner|baloo', 'File indexer. Turn off if you do not search file contents.'),
    ('disable', r'update|updater', 'Background updater. The app checks for updates when you open it.'),
]
OPTIONAL_SERVICES = ['cups.service', 'cups-browsed.service', 'ModemManager.service', 'bluetooth.service',
                     'avahi-daemon.service', 'whoopsie.service', 'apport.service', 'kerneloops.service']


def advice(text):
    t = text.lower()
    for verdict, pat, why in STARTUP_RULES:
        if re.search(pat, t):
            return verdict, why
    return 'optional', 'Not recognised. Not essential at login - turn it off if you do not need it running all the time.'


USER_AUTOSTART = os.path.join(HOME, '.config', 'autostart')
SYS_AUTOSTART = '/etc/xdg/autostart'


def autostart_enabled(d):
    return d.get('Hidden', 'false').lower() != 'true' and d.get('X-GNOME-Autostart-enabled', 'true').lower() != 'false'


def get_startup():
    items, seen = [], {}
    for base, src in ((SYS_AUTOSTART, 'auto-sys'), (USER_AUTOSTART, 'auto-user')):
        for p in sorted(glob.glob(os.path.join(base, '*.desktop'))):
            seen.setdefault(os.path.basename(p), {})[src] = p
    for fn, where in seen.items():
        sysd = parse_desktop(where['auto-sys']) if 'auto-sys' in where else None
        usrd = parse_desktop(where['auto-user']) if 'auto-user' in where else None
        d = usrd if usrd is not None else sysd
        if sysd is not None and sysd.get('NoDisplay', '').lower() == 'true':
            continue                                  # desktop-session plumbing; GNOME hides these too
        if usrd is not None and sysd is None and usrd.get('NoDisplay', '').lower() == 'true' and 'X-Tweakr23' not in usrd:
            continue
        name = d.get('Name', fn[:-8])
        cmd = d.get('Exec', '')
        verdict, why = advice(f'{fn} {name} {cmd}')
        items.append({'source': 'auto-sys' if sysd is not None else 'auto-user',
                      'sourceLabel': 'Startup Applications (system)' if sysd is not None else 'Startup Applications (you)',
                      'name': name, 'command': cmd, 'publisher': d.get('Comment', ''), 'enabled': autostart_enabled(d),
                      'verdict': verdict, 'why': why, 'taskPath': fn})
    # your own systemd user services
    udir = os.path.join(HOME, '.config', 'systemd', 'user')
    for p in glob.glob(os.path.join(udir, '*.service')):
        unit = os.path.basename(p)
        en = sh(['systemctl', '--user', 'is-enabled', unit], 10)[1].strip() == 'enabled'
        verdict, why = advice(unit + ' ' + read(p))
        items.append({'source': 'user-svc', 'sourceLabel': 'Your systemd service', 'name': unit, 'command': p,
                      'publisher': '', 'enabled': en, 'verdict': verdict, 'why': why, 'taskPath': unit})
    # a short list of optional system services
    for unit in OPTIONAL_SERVICES:
        code, out = sh(['systemctl', 'is-enabled', unit], 10, ok_codes=(0, 1))
        st = out.strip().splitlines()[0] if out.strip() else ''
        if st not in ('enabled', 'disabled'):
            continue
        verdict, why = advice(unit)
        items.append({'source': 'svc', 'sourceLabel': 'System service', 'name': unit, 'command': f'systemctl {unit}',
                      'publisher': '', 'enabled': st == 'enabled', 'verdict': verdict, 'why': why, 'taskPath': unit})
    return items


def set_startup(b):
    enable = bool(b.get('enable'))
    src, fn = b.get('source'), os.path.basename(str(b.get('taskPath', '')))
    if src in ('auto-sys', 'auto-user'):
        if not fn.endswith('.desktop'):
            raise RuntimeError('Bad entry.')
        os.makedirs(USER_AUTOSTART, exist_ok=True)
        user_p, sys_p = os.path.join(USER_AUTOSTART, fn), os.path.join(SYS_AUTOSTART, fn)
        if enable:
            if os.path.exists(user_p):
                if os.path.exists(sys_p) and 'X-Tweakr23-Override' in parse_desktop(user_p):
                    os.remove(user_p)                  # drop our override; system default comes back
                else:
                    edit_desktop(user_p, {'Hidden': 'false', 'X-GNOME-Autostart-enabled': 'true'})
        else:
            if not os.path.exists(user_p):
                shutil.copyfile(sys_p, user_p)
                edit_desktop(user_p, {'X-Tweakr23-Override': 'true'})
            edit_desktop(user_p, {'Hidden': 'true', 'X-GNOME-Autostart-enabled': 'false'})
        return
    if src == 'user-svc':
        if not re.match(r'^[\w@.\-]+\.service$', fn):
            raise RuntimeError('Bad unit.')
        sh(['systemctl', '--user', 'enable' if enable else 'disable', '--now', fn], 30)
        return
    if src == 'svc':
        if fn not in OPTIONAL_SERVICES:
            raise RuntimeError('Not an allowed service.')
        sudo_or_raise()
        code, out = sh(['systemctl', 'enable' if enable else 'disable', '--now', fn], 60, sudo=True)
        if code:
            raise RuntimeError(out.strip() or 'systemctl failed')
        return
    raise RuntimeError('Unknown startup source.')


# ---------------------------------------------------------------- turbo boost
PROTECTED = {'systemd', 'dbus-daemon', 'dbus-broker', 'gnome-shell', 'gnome-session-binary', 'gnome-session-ctl', 'mutter',
             'xorg', 'xwayland', 'gdm-wayland-session', 'gdm-x-session', 'pipewire', 'pipewire-pulse', 'wireplumber',
             'pulseaudio', 'at-spi-bus-launcher', 'at-spi2-registryd', 'ibus-daemon', 'ibus-x11', 'ibus-extension-gtk3',
             'ibus-engine-simple', 'ibus-portal', 'gnome-keyring-daemon', 'ssh-agent', 'gpg-agent', 'xdg-desktop-portal',
             'xdg-desktop-portal-gnome', 'xdg-desktop-portal-gtk', 'xdg-document-portal', 'xdg-permission-store',
             'gvfsd', 'gvfsd-fuse', 'gvfsd-metadata', 'goa-daemon', 'goa-identity-service', 'dconf-service',
             'evolution-source-registry', 'gjs', 'plasmashell', 'kwin_wayland', 'kwin_x11', 'ksmserver', 'kded5', 'kded6',
             'xfwm4', 'xfce4-session', 'xfce4-panel', 'xfdesktop', 'cinnamon', 'muffin', 'bash', 'zsh', 'fish', 'sh', 'sudo',
             'python3', 'snapd-desktop-integration', 'gnome-terminal-server', 'ptyxis', 'ptyxis-agent', 'kgx', 'systemd-logind'}
SUGGEST = re.compile(r'spotify|discord|telegram|slack|teams|zoom|skype|steam|dropbox|insync|megasync|tracker-miner|evolution-alarm|update-notifier|signal|whatsapp|element')
BROWSERS = re.compile(r'^(chrome|chromium|brave|msedge|microsoft-edge|firefox|vivaldi|opera)')


def user_procs():
    me = os.getpid()
    for pid in os.listdir('/proc'):
        if not pid.isdigit() or int(pid) == me:
            continue
        try:
            st = os.stat(f'/proc/{pid}')
            if st.st_uid != UID:
                continue
            status = read(f'/proc/{pid}/status')
            name = re.search(r'^Name:\s*(.+)$', status, re.M).group(1).strip()
            rss = re.search(r'^VmRSS:\s*(\d+)', status, re.M)
            cmdline = read(f'/proc/{pid}/cmdline').replace('\0', ' ')
        except Exception:
            continue
        if not rss or 'tweakr23-ui' in cmdline:
            continue
        yield int(pid), name, int(rss.group(1)) * 1024, cmdline


def get_turbo():
    groups = {}
    for pid, name, rss, cmd in user_procs():
        if name.lower() in PROTECTED or name.startswith(('gsd-', 'kworker', 'gnome-shell')):
            continue
        g = groups.setdefault(name, {'name': name, 'desc': '', 'count': 0, 'memory': 0, 'hasWindow': False,
                                     'browser': bool(BROWSERS.match(name.lower())), 'suggested': bool(SUGGEST.search(name.lower()))})
        g['count'] += 1
        g['memory'] += rss
    items = sorted(groups.values(), key=lambda x: -x['memory'])[:45]
    return {'mem': mem_info(), 'items': items}


def turbo_boost(b):
    before = mem_info()['free']
    names = [n for n in b.get('names', []) if re.match(r'^[\w.\-+ ]+$', str(n)) and n.lower() not in PROTECTED]
    report = []
    for n in names:
        pids = [pid for pid, name, _, _ in user_procs() if name == n]
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL if b.get('force') else signal.SIGTERM)
            except OSError:
                pass
        report.append(f'{n} - asked to quit ({len(pids)} process{"es" if len(pids) != 1 else ""})')
    time.sleep(2)
    return {'freed': max(0, mem_info()['free'] - before), 'report': report, 'mem': mem_info()}


# ---------------------------------------------------------------- browsers
def chromium_browsers():
    defs = [('Chrome', '~/.config/google-chrome', '~/.cache/google-chrome', ['google-chrome', 'google-chrome-stable'], 'chrome'),
            ('Chromium', '~/.config/chromium', '~/.cache/chromium', ['chromium', 'chromium-browser'], 'chrome'),
            ('Chromium (snap)', '~/snap/chromium/common/chromium', '~/snap/chromium/common/.cache/chromium', ['chromium'], 'chrome'),
            ('Brave', '~/.config/BraveSoftware/Brave-Browser', '~/.cache/BraveSoftware/Brave-Browser', ['brave-browser', 'brave'], 'brave'),
            ('Edge', '~/.config/microsoft-edge', '~/.cache/microsoft-edge', ['microsoft-edge', 'microsoft-edge-stable'], 'edge'),
            ('Vivaldi', '~/.config/vivaldi', '~/.cache/vivaldi', ['vivaldi', 'vivaldi-stable'], 'vivaldi'),
            ('Opera', '~/.config/opera', '~/.cache/opera', ['opera'], 'opera')]
    out = []
    for name, data, cache, exes, scheme in defs:
        data, cache = os.path.expanduser(data), os.path.expanduser(cache)
        if not os.path.isdir(data):
            continue
        profs = [p for p in glob.glob(os.path.join(data, '*')) if os.path.basename(p) == 'Default' or os.path.basename(p).startswith('Profile ')]
        if name == 'Opera':
            profs = [data]
        out.append({'name': name, 'data': data, 'cache': cache, 'exes': exes, 'scheme': scheme,
                    'running': lock_alive(os.path.join(data, 'SingletonLock')), 'profiles': profs})
    return out


def firefox_profiles():
    out = []
    for base, cache in (('~/.mozilla/firefox', '~/.cache/mozilla/firefox'),
                        ('~/snap/firefox/common/.mozilla/firefox', '~/snap/firefox/common/.cache/mozilla/firefox')):
        base, cache = os.path.expanduser(base), os.path.expanduser(cache)
        for p in glob.glob(os.path.join(base, '*')):
            if os.path.isdir(p) and os.path.exists(os.path.join(p, 'prefs.js')):
                out.append({'name': os.path.basename(p), 'path': p, 'cache': os.path.join(cache, os.path.basename(p)),
                            'running': lock_alive(os.path.join(p, 'lock'))})
    return out


# ---------------------------------------------------------------- junk
BROWSER_CACHE_DIRS = ['google-chrome', 'chromium', 'BraveSoftware', 'microsoft-edge', 'vivaldi', 'opera', 'mozilla', 'thumbnails']


def junk_cats():
    cache = os.path.join(HOME, '.cache')
    excl = tuple(os.path.join(cache, d) for d in BROWSER_CACHE_DIRS)
    cats = [
        {'id': 'cache', 'label': 'App caches (older than 7 days)', 'desc': 'Leftover cache files in ~/.cache that apps have not touched in a week.', 'safe': True,
         'targets': [{'dir': cache, 'age': 168, 'exclude': excl}]},
        {'id': 'tmp', 'label': 'Your temp files', 'desc': 'Your files in /tmp older than 24h.', 'safe': True, 'targets': [{'tmp': True, 'age': 24}]},
        {'id': 'thumbs', 'label': 'Thumbnail cache', 'desc': 'Rebuilds itself. Image folders load slower once afterwards.', 'safe': False,
         'targets': [{'dir': os.path.join(cache, 'thumbnails')}]},
        {'id': 'apt', 'label': 'Downloaded package files', 'desc': 'Installers apt already used (/var/cache/apt/archives). Needs admin.', 'safe': True, 'special': 'apt'},
        {'id': 'snaps', 'label': 'Old snap versions', 'desc': 'Snap keeps previous versions of every app. Needs admin.', 'safe': True, 'special': 'snaps'},
        {'id': 'journal', 'label': 'System logs older than 7 days', 'desc': 'Old systemd journal entries. Needs admin.', 'safe': True, 'special': 'journal'},
        {'id': 'crash', 'label': 'Crash reports', 'desc': 'Reports from past app crashes in /var/crash. Needs admin.', 'safe': True, 'special': 'crash'},
    ]
    bt, skipped = [], []
    for br in chromium_browsers():
        if br['running']:
            skipped.append(br['name'])
            continue
        for p in br['profiles']:
            rel = os.path.relpath(p, br['data'])
            for sub in ('Cache', 'Code Cache', 'GPUCache'):
                bt.append({'dir': os.path.normpath(os.path.join(br['cache'], rel, sub))})
                bt.append({'dir': os.path.join(p, sub)})
        bt += [{'dir': os.path.join(br['data'], s)} for s in ('ShaderCache', 'GrShaderCache')]
    for fp in firefox_profiles():
        if fp['running']:
            if 'Firefox' not in skipped:
                skipped.append('Firefox')
            continue
        bt.append({'dir': os.path.join(fp['cache'], 'cache2')})
    d = 'Cached web files. Sites load a bit slower once. Logins and history are untouched.'
    if skipped:
        d += f' Skipped (open right now): {", ".join(skipped)}.'
    cats.append({'id': 'browser', 'label': 'Browser caches', 'desc': d, 'safe': True, 'targets': bt})
    cats.append({'id': 'trash', 'label': 'Trash', 'desc': 'Permanently empties your Trash. Check it first if unsure.', 'safe': False,
                 'targets': [{'dir': os.path.join(HOME, '.local/share/Trash/files')}, {'dir': os.path.join(HOME, '.local/share/Trash/info')}]})
    return cats


def junk_files(cat):
    for t in cat.get('targets', []):
        if t.get('tmp'):
            cut = time.time() - t['age'] * 3600
            for root, dirs, files in os.walk('/tmp', followlinks=False):
                for fn in files:
                    fp = os.path.join(root, fn)
                    try:
                        st = os.lstat(fp)
                    except OSError:
                        continue
                    if st.st_uid == UID and st.st_mtime < cut:
                        yield fp, st.st_size
            continue
        for fp, sz, _ in files_under(t['dir'], t.get('age', 0), t.get('exclude', ())):
            yield fp, sz


def old_snaps():
    out = []
    code, txt = sh(['snap', 'list', '--all'], 30)
    for ln in txt.splitlines()[1:]:
        cols = ln.split()
        if len(cols) >= 6 and 'disabled' in cols[-1]:
            f = f'/var/lib/snapd/snaps/{cols[0]}_{cols[2]}.snap'
            out.append((cols[0], cols[2], os.path.getsize(f) if os.path.exists(f) else 0))
    return out


def journal_old_size():
    code, txt = sh(['journalctl', '--disk-usage'], 20)
    m = re.search(r'take up ([\d.]+)([KMGT])', txt)
    if not m:
        return 0
    total = float(m.group(1)) * {'K': 1 << 10, 'M': 1 << 20, 'G': 1 << 30, 'T': 1 << 40}[m.group(2)]
    return total * 0.5                                  # rough estimate of the part older than a week


def special_size(cat):
    s = cat.get('special')
    if s == 'apt':
        return sum(os.path.getsize(f) for f in glob.glob('/var/cache/apt/archives/*.deb')), len(glob.glob('/var/cache/apt/archives/*.deb'))
    if s == 'snaps':
        o = old_snaps(); return sum(x[2] for x in o), len(o)
    if s == 'journal':
        return journal_old_size(), 1
    if s == 'crash':
        fs = glob.glob('/var/crash/*'); return sum(os.path.getsize(f) for f in fs if os.path.isfile(f)), len(fs)
    return 0, 0


def junk_scan():
    out = []
    for c in junk_cats():
        if c.get('special'):
            size, count = special_size(c)
        else:
            size = count = 0
            for _, sz in junk_files(c):
                size += sz; count += 1
        out.append({'id': c['id'], 'label': c['label'], 'desc': c['desc'], 'safe': c['safe'], 'size': size, 'count': count})
    return {'items': out}


def junk_clean(ids):
    total, report = 0, []
    for c in junk_cats():
        if c['id'] not in ids:
            continue
        freed = failed = 0
        s = c.get('special')
        if s:
            if not need_sudo():
                report.append(f'{c["label"]}: skipped - needs admin (start with tweakr23.sh)')
                continue
            freed = special_size(c)[0]
            if s == 'apt':
                sh(['apt-get', 'clean'], 120, sudo=True)
            elif s == 'snaps':
                for name, rev, _ in old_snaps():
                    sh(['snap', 'remove', name, f'--revision={rev}'], 300, sudo=True)
            elif s == 'journal':
                before = journal_old_size() * 2
                sh(['journalctl', '--vacuum-time=7d'], 120, sudo=True)
                freed = max(0, before - journal_old_size() * 2)
            elif s == 'crash':
                sh('rm -f /var/crash/*', 30, sudo=True)
        else:
            for fp, sz in list(junk_files(c)):
                try:
                    os.remove(fp); freed += sz
                except OSError:
                    failed += 1
            for t in c.get('targets', []):
                if t.get('dir'):
                    remove_empty_dirs(t['dir'])
        total += freed
        line = f'{c["label"]}: freed {human(freed)}'
        if failed:
            line += f' ({failed} in-use files skipped)'
        report.append(line)
    return {'freed': total, 'report': report}


# ---------------------------------------------------------------- privacy & tweaks
_schemas = None


def schema_ok(schema):
    global _schemas
    if _schemas is None:
        _schemas = set(sh(['gsettings', 'list-schemas'], 10)[1].split()) if has('gsettings') else set()
    return schema in _schemas


def gs_get(schema, key):
    code, out = sh(['gsettings', 'get', schema, key], 10)
    return out.strip() if code == 0 else None


TOGGLES = [
    # id, group, label, desc, list of (schema, key, on_value, off_value or None=reset)
    ('recentoff', 'privacy', 'Stop remembering recent files', 'Files and apps stop recording what you opened.', [('org.gnome.desktop.privacy', 'remember-recent-files', 'false', None)]),
    ('autotemp', 'privacy', 'Auto-delete old temp files', 'GNOME cleans its temp files after 30 days.', [('org.gnome.desktop.privacy', 'remove-old-temp-files', 'true', None)]),
    ('autotrash', 'privacy', 'Auto-empty old Trash', 'Items older than 30 days leave the Trash on their own.', [('org.gnome.desktop.privacy', 'remove-old-trash-files', 'true', None)]),
    ('reports', 'privacy', 'No automatic problem reports', 'Stops sending crash and problem reports.', [('org.gnome.desktop.privacy', 'report-technical-problems', 'false', None)]),
    ('usage', 'privacy', 'No software usage stats', 'Stops sending app usage statistics.', [('org.gnome.desktop.privacy', 'send-software-usage-stats', 'false', None)]),
    ('location', 'privacy', 'Turn off location services', 'Apps cannot ask for your location.', [('org.gnome.system.location', 'enabled', 'false', None)]),
    ('aptnews', 'privacy', 'No Ubuntu Pro ads in apt', 'Removes the "news" and Pro promos printed by apt. Needs admin.', 'special'),
    ('hidden', 'tweak', 'Show hidden files', 'Shows dot-files and folders like .config in Files and file pickers.', [('org.gtk.gtk4.Settings.FileChooser', 'show-hidden', 'true', None), ('org.gtk.Settings.FileChooser', 'show-hidden', 'true', None)]),
    ('battery', 'tweak', 'Show battery percentage', 'Adds the % next to the battery icon.', [('org.gnome.desktop.interface', 'show-battery-percentage', 'true', None)]),
    ('minimize', 'tweak', 'Click dock icon to minimize', 'Clicking an open app in the dock hides it, like Windows.', [('org.gnome.shell.extensions.dash-to-dock', 'click-action', "'minimize'", None)]),
    ('hotcorner', 'tweak', 'Turn off hot corner', 'Stops Activities opening when the mouse hits the top-left corner.', [('org.gnome.desktop.interface', 'enable-hot-corners', 'false', None)]),
    ('weekday', 'tweak', 'Show weekday in clock', 'Top bar shows "Thu" next to the time.', [('org.gnome.desktop.interface', 'clock-show-weekday', 'true', None)]),
    ('swappy', 'tweak', 'Use RAM before swap', 'Sets swappiness to 10 so apps stay in memory. Good with 8 GB+. Needs admin.', 'special'),
]


def toggle_state(t):
    tid, _, _, _, spec = t
    if spec == 'special':
        if tid == 'aptnews':
            out = sh(['pro', 'config', 'show', 'apt_news'], 15)[1] if has('pro') else ''
            return 'False' in out or 'false' in out
        if tid == 'swappy':
            return read('/proc/sys/vm/swappiness').strip() == '10'
    for schema, key, on, _ in spec:
        if schema_ok(schema):
            return gs_get(schema, key) == on
    return False


def toggle_available(t):
    tid, _, _, _, spec = t
    if spec == 'special':
        return (tid == 'aptnews' and has('pro')) or tid == 'swappy'
    return any(schema_ok(s) for s, _, _, _ in spec)


def get_toggles(group):
    return [{'id': t[0], 'label': t[2], 'desc': t[3], 'on': toggle_state(t), 'explorer': False}
            for t in TOGGLES if t[1] == group and toggle_available(t)]


def set_toggle(b):
    t = next((x for x in TOGGLES if x[0] == b.get('id')), None)
    if not t:
        raise RuntimeError('Unknown setting.')
    want = bool(b.get('on'))
    tid, _, label, _, spec = t
    if spec == 'special':
        sudo_or_raise()
        if tid == 'aptnews':
            sh(['pro', 'config', 'set', f'apt_news={"false" if want else "true"}'], 30, sudo=True)
        elif tid == 'swappy':
            conf = '/etc/sysctl.d/99-tweakr23.conf'
            if want:
                sh(f"echo 'vm.swappiness=10' > {conf} && sysctl -w vm.swappiness=10", 20, sudo=True)
            else:
                sh(f'rm -f {conf} && sysctl -w vm.swappiness=60', 20, sudo=True)
    else:
        for schema, key, on, off in spec:
            if not schema_ok(schema):
                continue
            if want:
                sh(['gsettings', 'set', schema, key, on], 10)
            elif off is None:
                sh(['gsettings', 'reset', schema, key], 10)
            else:
                sh(['gsettings', 'set', schema, key, off], 10)
    return {'message': f'{label}: {"on" if want else "off"}'}


def privacy_sweep(ids):
    r = []
    if 'recent' in ids:
        p = os.path.join(HOME, '.local/share/recently-used.xbel')
        if os.path.exists(p):
            with open(p, 'w') as fh:
                fh.write('<?xml version="1.0" encoding="UTF-8"?>\n<xbel version="1.0" xmlns:bookmark="http://www.freedesktop.org/standards/desktop-bookmarks" xmlns:mime="http://www.freedesktop.org/standards/shared-mime-info"></xbel>\n')
        r.append('Recent files list: cleared')
    if 'shellhist' in ids:
        p = os.path.join(HOME, '.bash_history')
        if os.path.exists(p):
            open(p, 'w').close()
        r.append('Terminal history: cleared')
    if 'clipboard' in ids:
        if has('wl-copy'):
            sh(['wl-copy', '--clear'], 5)
        elif has('xclip'):
            sh("printf '' | xclip -selection clipboard", 5)
        elif has('xsel'):
            sh(['xsel', '-bc'], 5)
        else:
            r.append('Clipboard: install wl-clipboard or xclip to clear it from here'); ids = [i for i in ids if i != 'clipboard']
        if 'clipboard' in ids:
            r.append('Clipboard: cleared')
    if 'dns' in ids:
        code, _ = sh(['resolvectl', 'flush-caches'], 10, sudo=need_sudo())
        r.append('DNS cache: flushed' if code == 0 else 'DNS cache: could not flush (systemd-resolved not running?)')
    if 'cookies' in ids or 'history' in ids:
        for br in chromium_browsers():
            if br['running']:
                r.append(f'{br["name"]}: skipped - close it first'); continue
            names = []
            if 'cookies' in ids:
                names += ['Cookies', 'Cookies-journal', 'Network/Cookies', 'Network/Cookies-journal']
            if 'history' in ids:
                names += ['History', 'History-journal', 'Visited Links', 'Top Sites', 'Top Sites-journal']
            for p in br['profiles']:
                for n in names:
                    fp = os.path.join(p, n)
                    if os.path.exists(fp):
                        try: os.remove(fp)
                        except OSError: pass
            r.append(f'{br["name"]}: cleared {" and ".join(x for x in ("cookies", "history") if x in ids)}')
        if 'cookies' in ids:
            for fp in firefox_profiles():
                if fp['running']:
                    r.append('Firefox: skipped - close it first'); continue
                try: os.remove(os.path.join(fp['path'], 'cookies.sqlite'))
                except OSError: pass
                r.append(f'Firefox ({fp["name"]}): cookies cleared')
    return {'report': r}


# ---------------------------------------------------------------- extensions
RISKY = {'webRequest', 'webRequestBlocking', 'cookies', 'history', 'debugger', 'nativeMessaging', 'proxy', 'management',
         'clipboardRead', 'downloads', 'privacy', 'declarativeNetRequestWithHostAccess'}
ALLSITES = re.compile(r'<all_urls>|^\*://\*/|^https?://\*/|^\*://\*\.')


def ext_risk(perms):
    p = [str(x) for x in perms if isinstance(x, str)]
    allsites = any(ALLSITES.search(x) for x in p)
    sens = sorted(set(x for x in p if x in RISKY))
    level = 'high' if allsites and sens else 'medium' if allsites or len(sens) >= 2 else 'low'
    summary = (['reads/changes data on all websites'] if allsites else []) + sens
    return level, ', '.join(summary)


def manifest_name(verdir, m):
    n = str(m.get('name', ''))
    mm = re.match(r'^__MSG_(.+)__$', n)
    if mm:
        key = mm.group(1).lower()
        for loc in [m.get('default_locale'), 'en', 'en_US']:
            if not loc:
                continue
            f = os.path.join(verdir, '_locales', loc, 'messages.json')
            try:
                msgs = json.loads(read(f))
                for k, v in msgs.items():
                    if k.lower() == key:
                        return v.get('message', n)
            except Exception:
                pass
    return n


POLICY_DIRS = ['/etc/opt/chrome/policies/managed', '/etc/chromium/policies/managed', '/etc/chromium-browser/policies/managed',
               '/etc/brave/policies/managed', '/etc/opt/edge/policies/managed']


def policy_forced():
    forced = {}
    for d in POLICY_DIRS:
        for f in glob.glob(os.path.join(d, '*.json')):
            try:
                data = json.loads(read(f))
            except Exception:
                continue
            for entry in data.get('ExtensionInstallForcelist', []) or []:
                forced[str(entry).split(';')[0]] = f
    return forced


def get_extensions():
    forced, groups = policy_forced(), []
    for br in chromium_browsers():
        exts = []
        for p in br['profiles']:
            ed = os.path.join(p, 'Extensions')
            for idd in glob.glob(os.path.join(ed, '*')):
                eid = os.path.basename(idd)
                if not re.match(r'^[a-p]{32}$', eid):
                    continue
                vers = sorted(glob.glob(os.path.join(idd, '*')), key=lambda x: os.path.getmtime(x), reverse=True)
                if not vers:
                    continue
                try:
                    m = json.loads(read(os.path.join(vers[0], 'manifest.json')))
                except Exception:
                    continue
                if m.get('theme'):
                    continue
                perms = list(m.get('permissions', []) or []) + list(m.get('host_permissions', []) or [])
                for cs in m.get('content_scripts', []) or []:
                    perms += cs.get('matches', []) or []
                level, summary = ext_risk(perms)
                store = bool(re.search(r'clients2\.google\.com|edge\.microsoft\.com|opera\.com|vivaldi', str(m.get('update_url', ''))))
                exts.append({'id': eid, 'name': manifest_name(vers[0], m), 'version': str(m.get('version', '')), 'profile': os.path.basename(p),
                             'profilePath': p, 'risk': level, 'perms': summary, 'sideloaded': not store, 'policy': eid in forced})
        groups.append({'browser': br['name'], 'running': br['running'], 'items': exts})
    ff, ffr = [], False
    profs = firefox_profiles()
    for fp in profs:
        ffr = ffr or fp['running']
        try:
            data = json.loads(read(os.path.join(fp['path'], 'extensions.json')))
        except Exception:
            continue
        for a in data.get('addons', []):
            if a.get('type') != 'extension' or a.get('location') != 'app-profile':
                continue
            up = a.get('userPermissions') or {}
            level, summary = ext_risk((up.get('permissions') or []) + (up.get('origins') or []))
            ff.append({'id': a.get('id'), 'name': (a.get('defaultLocale') or {}).get('name', a.get('id')), 'version': a.get('version', ''),
                       'profile': fp['name'], 'profilePath': fp['path'], 'risk': level, 'perms': summary, 'sideloaded': False,
                       'policy': False, 'active': bool(a.get('active')), 'file': a.get('path', '')})
    if profs:
        groups.append({'browser': 'Firefox', 'running': ffr, 'items': ff})
    return {'groups': groups}


def open_ext_page(b):
    if b.get('browser') == 'Firefox':
        for exe in ('firefox',):
            if has(exe):
                return launch(exe, 'about:addons')
        raise RuntimeError('Firefox not found.')
    br = next((x for x in chromium_browsers() if x['name'] == b.get('browser')), None)
    if not br:
        raise RuntimeError('Browser not found.')
    url = f'{br["scheme"]}://extensions/' + (f'?id={b["id"]}' if re.match(r'^[a-p]{32}$', str(b.get('id', ''))) else '')
    exe = next((e for e in br['exes'] if has(e)), None)
    if not exe:
        raise RuntimeError(f'Could not find the {br["name"]} program.')
    launch(exe, url)


def remove_ext(b):
    if b.get('browser') == 'Firefox':
        fp = next((x for x in firefox_profiles() if x['path'] == b.get('profilePath')), None)
        if not fp:
            raise RuntimeError('Profile not found.')
        if fp['running']:
            raise RuntimeError('Close Firefox first.')
        f = str(b.get('file', ''))
        if not os.path.realpath(f).startswith(os.path.realpath(fp['path']) + os.sep):
            raise RuntimeError('Unexpected extension path.')
        shutil.rmtree(f) if os.path.isdir(f) else os.remove(f)
        return {'message': 'Removed from Firefox. It disappears next time Firefox starts.'}
    eid = str(b.get('id', ''))
    if not re.match(r'^[a-p]{32}$', eid):
        raise RuntimeError('Bad extension id.')
    br = next((x for x in chromium_browsers() if x['name'] == b.get('browser')), None)
    if not br:
        raise RuntimeError('Browser not found.')
    if br['running']:
        raise RuntimeError(f'Close {br["name"]} completely first.')
    prof = next((p for p in br['profiles'] if p == b.get('profilePath')), None)
    if not prof:
        raise RuntimeError('Profile not found.')
    msg = []
    pf = policy_forced().get(eid)
    if pf:
        sudo_or_raise()
        data = json.loads(read(pf))
        data['ExtensionInstallForcelist'] = [e for e in data.get('ExtensionInstallForcelist', []) if not str(e).startswith(eid)]
        tmp = os.path.join(STATE_DIR, 'policy.tmp.json')
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(tmp, 'w') as fh:
            json.dump(data, fh, indent=2)
        sh(['cp', tmp, pf], 10, sudo=True)
        os.remove(tmp)
        msg.append('Removed the policy that force-installed it.')
    for sub in (f'Extensions/{eid}', f'Local Extension Settings/{eid}', f'Sync Extension Settings/{eid}'):
        shutil.rmtree(os.path.join(prof, sub), ignore_errors=True)
    msg.append(f'Deleted its files from {br["name"]}. If sync brings it back, remove it from the extensions page too.')
    return {'message': ' '.join(msg)}


# ---------------------------------------------------------------- launchers ("shortcut fix")
def xdg_dir(name, fallback):
    code, out = sh(['xdg-user-dir', name], 5)
    return out.strip() if code == 0 and out.strip() else os.path.join(HOME, fallback)


def shortcut_roots():
    return [('App menu (you)', os.path.join(HOME, '.local/share/applications')), ('Desktop', xdg_dir('DESKTOP', 'Desktop'))]


def get_broken_shortcuts():
    out = []
    for label, root in shortcut_roots():
        if not os.path.isdir(root):
            continue
        for fp in glob.glob(os.path.join(root, '**', '*'), recursive=True):
            if os.path.islink(fp) and not os.path.exists(fp):
                out.append({'path': fp, 'name': os.path.basename(fp), 'where': label, 'target': os.readlink(fp), 'why': 'target missing'})
                continue
            if not fp.endswith('.desktop') or not os.path.isfile(fp):
                continue
            d = parse_desktop(fp)
            if d.get('Type', 'Application') != 'Application' or d.get('Hidden', '').lower() == 'true':
                continue
            target = d.get('TryExec') or exec_binary(d.get('Exec', ''))
            if not target or target in ('flatpak', 'snap', 'env', 'sh', 'bash'):
                continue
            exists = os.path.exists(target) if os.path.isabs(target) else has(target)
            if not exists:
                out.append({'path': fp, 'name': d.get('Name', os.path.basename(fp)), 'where': label, 'target': target, 'why': 'target missing'})
    return {'items': out}


def remove_shortcuts(paths):
    roots = [os.path.realpath(r) for _, r in shortcut_roots()]
    n = 0
    for p in paths:
        p = str(p)
        parent = os.path.realpath(os.path.dirname(p))
        if not any(parent == r or parent.startswith(r + os.sep) for r in roots):
            continue
        code, _ = sh(['gio', 'trash', p], 10)
        if code == 0:
            n += 1
    return {'message': f'Moved {n} item(s) to the Trash.'}


# ---------------------------------------------------------------- drivers
def lspci_devices():
    code, out = sh(['lspci', '-k'], 20)
    devs, cur = [], None
    for ln in out.splitlines():
        if ln and not ln[0].isspace():
            m = re.match(r'^(\S+)\s+([^:]+):\s+(.*)$', ln)
            if m:
                cur = {'slot': m.group(1), 'cls': m.group(2), 'device': m.group(3), 'driver': '', 'modules': ''}
                devs.append(cur)
        elif cur:
            s = ln.strip()
            if s.startswith('Kernel driver in use:'):
                cur['driver'] = s.split(':', 1)[1].strip()
            elif s.startswith('Kernel modules:'):
                cur['modules'] = s.split(':', 1)[1].strip()
    return devs


QUIET_CLASSES = re.compile(r'bridge|signal processing|system peripheral|communication controller|memory controller|unassigned|non-essential|performance counters|encryption', re.I)


def get_drivers():
    devs = lspci_devices()
    drivers = [{'device': d['device'], 'cls': d['cls'], 'provider': d['driver'], 'version': d['modules'] or '-', 'date': 'PCI ' + d['slot'], 'age': None, 'inbox': False}
               for d in devs]
    problems = [{'device': d['device'], 'code': None, 'problem': f'No driver in use ({d["cls"]})'} for d in devs if not d['driver'] and not QUIET_CLASSES.search(d['cls'])]
    gpus = []
    for d in devs:
        if re.search(r'VGA|3D|Display', d['cls']):
            ver = d['driver'] or 'none'
            if d['driver'] == 'nvidia' and has('nvidia-smi'):
                ver = 'nvidia ' + sh(['nvidia-smi', '--query-gpu=driver_version', '--format=csv,noheader'], 10)[1].strip()
            gpus.append({'name': d['device'], 'version': ver, 'date': ''})
    return {'drivers': drivers, 'problems': problems, 'gpus': gpus, 'hags': []}


def find_driver_updates():
    items = []
    if has('ubuntu-drivers'):
        code, out = sh(['ubuntu-drivers', 'list'], 120)
        for ln in out.splitlines():
            ln = ln.strip()
            if ln and not ln.startswith(('ERROR', 'WARNING', 'udevadm')):
                items.append({'title': ln.split(',')[0], 'provider': 'ubuntu-drivers', 'cls': 'Driver package', 'date': ''})
        code, out = sh(['ubuntu-drivers', 'devices'], 120)
        rec = re.findall(r'driver\s*:\s*(\S+).*recommended', out)
        for r in rec:
            for it in items:
                if it['title'] == r:
                    it['provider'] = 'ubuntu-drivers (recommended)'
    if has('fwupdmgr'):
        code, out = sh(['fwupdmgr', 'get-updates', '--json', '--no-unreported-check'], 120, ok_codes=(0, 2))
        try:
            for dev in json.loads(out).get('Devices', []):
                for rel in dev.get('Releases', [])[:1]:
                    items.append({'title': f'{dev.get("Name")} firmware {rel.get("Version", "")}', 'provider': dev.get('Vendor', 'fwupd'),
                                  'cls': 'Firmware', 'date': ''})
        except Exception:
            pass
    if not has('ubuntu-drivers') and not has('fwupdmgr'):
        raise RuntimeError('Neither ubuntu-drivers nor fwupd is installed.')
    return {'items': items}


# ---------------------------------------------------------------- hardware health
def cpu_load():
    def snap():
        v = list(map(int, read('/proc/stat').splitlines()[0].split()[1:]))
        return sum(v), v[3] + (v[4] if len(v) > 4 else 0)
    t1, i1 = snap(); time.sleep(0.25); t2, i2 = snap()
    return round(100 * (1 - (i2 - i1) / max(1, t2 - t1)))


def smart(dev):
    if not has('smartctl') or not need_sudo():
        return None
    code, out = sh(['smartctl', '-j', '-a', f'/dev/{dev}'], 30, sudo=True, ok_codes=tuple(range(256)))
    try:
        return json.loads(out)
    except Exception:
        return None


def disk_list():
    code, out = sh(['lsblk', '-J', '-b', '-d', '-o', 'NAME,MODEL,SIZE,ROTA,TRAN,TYPE'], 10)
    try:
        return [d for d in json.loads(out)['blockdevices'] if d.get('type') == 'disk' and not re.match(r'^(loop|zram|ram)', d['name'])]
    except Exception:
        return []


def get_health():
    os_name = re.search(r'PRETTY_NAME="?([^"\n]+)', read('/etc/os-release'))
    cpuinfo = read('/proc/cpuinfo')
    model = re.search(r'model name\s*:\s*(.+)', cpuinfo)
    cores = len(set(re.findall(r'core id\s*:\s*(\d+)', cpuinfo))) or os.cpu_count()
    disks = []
    for d in disk_list():
        s = smart(d['name'])
        entry = {'name': (d.get('model') or d['name']).strip(), 'media': 'NVMe SSD' if d['name'].startswith('nvme') else ('HDD' if d.get('rota') in (True, '1', 1) else 'SSD'),
                 'bus': (d.get('tran') or '').upper(), 'size': int(d.get('size') or 0), 'health': 'Unknown', 'temp': None, 'wear': None, 'hours': None,
                 'readErr': None, 'writeErr': None, 'hint': '' if has('smartctl') else 'Install smartmontools for drive health: sudo apt install smartmontools'}
        if s:
            passed = (s.get('smart_status') or {}).get('passed')
            entry['health'] = 'Healthy' if passed else ('Unhealthy' if passed is False else 'Unknown')
            entry['temp'] = (s.get('temperature') or {}).get('current')
            entry['hours'] = (s.get('power_on_time') or {}).get('hours')
            nv = s.get('nvme_smart_health_information_log') or {}
            if nv:
                entry['wear'] = nv.get('percentage_used'); entry['readErr'] = nv.get('media_errors', 0); entry['writeErr'] = 0
            else:
                for a in (s.get('ata_smart_attributes') or {}).get('table', []):
                    if a.get('name') in ('Reported_Uncorrect', 'Offline_Uncorrectable'):
                        entry['readErr'] = (entry['readErr'] or 0) + (a.get('raw') or {}).get('value', 0)
        elif has('smartctl'):
            entry['hint'] = 'Start Tweakr23 with tweakr23.sh (admin) to read SMART health.'
        disks.append(entry)
    bat = None
    for b in glob.glob('/sys/class/power_supply/BAT*'):
        full = read(b + '/energy_full') or read(b + '/charge_full')
        design = read(b + '/energy_full_design') or read(b + '/charge_full_design')
        try:
            hp = round(100 * int(full) / int(design))
        except Exception:
            hp = None
        bat = {'charge': read(b + '/capacity').strip(), 'design': design.strip(), 'full': full.strip(), 'health': hp}
        break
    temps = []
    for z in sorted(glob.glob('/sys/class/thermal/thermal_zone*')):
        if re.search(r'pkg|cpu|x86|acpitz|k10temp', read(z + '/type'), re.I):
            try:
                temps.append(round(int(read(z + '/temp')) / 1000))
            except Exception:
                pass
    code, out = sh('journalctl -p 3 --since "7 days ago" -o json --output-fields=SYSLOG_IDENTIFIER,_COMM -q --no-pager -n 5000', 60)
    counts = {}
    for ln in out.splitlines():
        try:
            j = json.loads(ln)
            k = j.get('SYSLOG_IDENTIFIER') or j.get('_COMM') or 'unknown'
            counts[k] = counts.get(k, 0) + 1
        except Exception:
            pass
    top = [{'source': k, 'count': v} for k, v in sorted(counts.items(), key=lambda x: -x[1])[:6]]
    oops = len(sh('journalctl -k --since "30 days ago" -q --no-pager -g "Oops|kernel BUG|Kernel panic"', 60)[1].strip().splitlines())
    kerr = len(sh('journalctl -k -p 2 --since "30 days ago" -q --no-pager', 60)[1].strip().splitlines())
    up = float(read('/proc/uptime').split()[0])
    gpus = [g['name'] for g in get_drivers()['gpus']]
    mods = []
    if need_sudo() and has('dmidecode'):
        for blk in sh(['dmidecode', '-t', 'memory'], 20, sudo=True)[1].split('\n\n'):
            m = re.search(r'^\s*Size:\s*(\d+)\s*(GB|MB)', blk, re.M)
            if 'Memory Device' in blk and m:
                spd = re.search(r'Configured Memory Speed:\s*(\d+)', blk) or re.search(r'^\s*Speed:\s*(\d+)', blk, re.M)
                mods.append({'size': int(m.group(1)) * (1 << 30 if m.group(2) == 'GB' else 1 << 20), 'speed': int(spd.group(1)) if spd else None})
    return {'os': os_name.group(1) if os_name else 'Linux', 'uptimeHours': round(up / 3600, 1),
            'cpu': {'name': model.group(1).strip() if model else 'CPU', 'cores': cores, 'threads': os.cpu_count(), 'load': cpu_load()},
            'mem': mem_info(), 'modules': mods, 'gpus': gpus, 'disks': disks, 'battery': bat, 'temps': temps[:3],
            'errors7d': sum(counts.values()), 'topErrors': top, 'unexpectedShutdowns30d': kerr, 'bluescreens30d': oops}


# ---------------------------------------------------------------- disk check
FSCK_STATE = os.path.join(STATE_DIR, 'fsck-pending.json')


def tune2fs(dev):
    code, out = sh(['tune2fs', '-l', dev], 20, sudo=True)
    info = {}
    for ln in out.splitlines():
        k, _, v = ln.partition(':')
        info[k.strip()] = v.strip()
    return info


def restore_fsck_counts():
    """After a requested boot-time check has run, put the mount-count limit back."""
    try:
        pending = json.loads(read(FSCK_STATE, '{}'))
    except Exception:
        pending = {}
    if not pending or not need_sudo():
        return
    left = {}
    for dev, rec in pending.items():
        info = tune2fs(dev)
        try:
            last = datetime.datetime.strptime(info.get('Last checked', ''), '%a %b %d %H:%M:%S %Y').timestamp()
        except Exception:
            last = 0
        if last > rec['at']:
            sh(['tune2fs', '-c', str(rec['old']), dev], 20, sudo=True)
        else:
            left[dev] = rec
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(FSCK_STATE, 'w') as fh:
        json.dump(left, fh)


def get_volumes():
    code, out = sh(['findmnt', '-J', '-b', '-o', 'TARGET,SOURCE,FSTYPE,SIZE,AVAIL,LABEL', '-t', 'ext4,ext3,btrfs,xfs,vfat,exfat,ntfs,ntfs3,f2fs'], 10)
    items = []
    try:
        fs = json.loads(out).get('filesystems', [])
    except Exception:
        fs = []
    def walk(lst):
        for f in lst:
            yield f
            yield from walk(f.get('children', []) or [])
    seen = set()
    for f in walk(fs):
        src = f.get('source', '')
        if not src.startswith('/dev/') or f['target'].startswith(('/snap', '/boot/efi', '/var/snap')) or src in seen:
            continue
        seen.add(src)
        items.append({'id': f['target'], 'name': f['target'], 'label': f.get('label') or os.path.basename(src.split('[')[0]),
                      'fs': f.get('fstype', ''), 'size': int(f.get('size') or 0), 'free': int(f.get('avail') or 0), 'health': '', 'dev': src.split('[')[0]})
    return {'items': items}


def volume_action(b):
    vol = next((v for v in get_volumes()['items'] if v['id'] == b.get('id')), None)
    if not vol:
        raise RuntimeError('Drive not found.')
    sudo_or_raise()
    dev, fs, mode = vol['dev'], vol['fs'], b.get('mode')
    parent = sh(['lsblk', '-no', 'PKNAME', dev], 10)[1].strip().splitlines()
    parent = parent[0] if parent else ''
    if mode == 'scan':
        msgs = []
        if fs.startswith('ext'):
            info = tune2fs(dev)
            state = info.get('Filesystem state', 'unknown')
            msgs.append(f'File system state: {state}.' + (' Use "Check at boot" to repair.' if 'error' in state.lower() or 'not clean' in state.lower() else ''))
        elif fs == 'btrfs':
            code, out = sh(['btrfs', 'device', 'stats', vol['id']], 30, sudo=True)
            errs = sum(int(x) for x in re.findall(r'\s(\d+)$', out, re.M))
            msgs.append('No btrfs errors recorded.' if errs == 0 else f'{errs} btrfs errors recorded - run "Repair (btrfs scrub)".')
        else:
            msgs.append(f'{fs} drives are checked by unmounting and running fsck from a terminal.')
        if parent:
            s = smart(parent)
            if s and 'smart_status' in s:
                msgs.append('SMART: drive reports healthy.' if s['smart_status'].get('passed') else 'SMART: drive reports FAILING - back it up now.')
        return {'result': 'ok', 'message': ' '.join(msgs)}
    if mode == 'spotfix':
        if fs != 'btrfs':
            return {'result': 'n/a', 'message': 'Online repair is only possible on btrfs. For ext4 use "Check at boot".'}
        terminal('Tweakr23 - btrfs scrub', f'sudo btrfs scrub start -B -d "{vol["id"]}"')
        return {'result': 'started', 'message': 'Scrub running in a terminal window.'}
    if mode == 'offline':
        if not fs.startswith('ext'):
            return {'result': 'n/a', 'message': 'Check at boot works for ext2/3/4 drives.'}
        info = tune2fs(dev)
        cur = info.get('Mount count', '0')
        old = info.get('Maximum mount count', '-1')
        code, out = sh(['tune2fs', '-c', cur, dev], 20, sudo=True)
        if code:
            raise RuntimeError(out.strip() or 'tune2fs failed')
        os.makedirs(STATE_DIR, exist_ok=True)
        try:
            pending = json.loads(read(FSCK_STATE, '{}'))
        except Exception:
            pending = {}
        pending[dev] = {'old': old, 'at': time.time()}
        with open(FSCK_STATE, 'w') as fh:
            json.dump(pending, fh)
        return {'result': 'scheduled', 'message': 'Check scheduled for the next boot. Tweakr23 restores the normal setting the next time you open it.'}
    raise RuntimeError('Unknown mode.')


# ---------------------------------------------------------------- system tools
def power_profile():
    if has('powerprofilesctl'):
        p = sh(['powerprofilesctl', 'get'], 10)[1].strip()
        return {'power-saver': 'Power saver', 'balanced': 'Balanced', 'performance': 'Performance'}.get(p, p or 'unknown')
    return 'n/a (no power-profiles-daemon)'


def system_action(b):
    a = b.get('id')
    docs = xdg_dir('DOCUMENTS', 'Documents')
    if a == 'restorepoint':
        if not has('timeshift'):
            raise RuntimeError('Timeshift is not installed. Install it with: sudo apt install timeshift')
        terminal('Tweakr23 - snapshot', 'sudo timeshift --create --comments "Tweakr23 $(date +%F_%H:%M)"')
        return 'Snapshot running in a terminal window.'
    if a == 'openrestore':
        for exe in ('timeshift-launcher', 'timeshift-gtk'):
            if has(exe):
                launch(exe); return 'Timeshift opened.'
        raise RuntimeError('Timeshift is not installed. Install it with: sudo apt install timeshift')
    if a in ('power-saver', 'power-balanced', 'power-high'):
        if not has('powerprofilesctl'):
            raise RuntimeError('power-profiles-daemon is not installed.')
        prof = {'power-saver': 'power-saver', 'power-balanced': 'balanced', 'power-high': 'performance'}[a]
        code, out = sh(['powerprofilesctl', 'set', prof], 10)
        if code:
            raise RuntimeError(out.strip() or 'This PC does not support that profile.')
        return f'Power profile: {power_profile()}'
    if a == 'optimize':
        sudo_or_raise()
        code, out = sh(['fstrim', '-av'], 300, sudo=True)
        return 'TRIM done. ' + ' '.join(out.strip().splitlines()[:4])
    if a == 'repair':
        terminal('Tweakr23 - update & repair', 'sudo dpkg --configure -a && sudo apt-get install -f -y && sudo apt update && sudo apt full-upgrade')
        return 'Package repair and upgrade running in a terminal window.'
    if a == 'autoremove':
        terminal('Tweakr23 - autoremove', 'sudo apt autoremove --purge')
        return 'Cleaning unused packages in a terminal window.'
    if a == 'flatpak':
        if not has('flatpak'):
            raise RuntimeError('Flatpak is not installed.')
        terminal('Tweakr23 - flatpak cleanup', 'flatpak uninstall --unused')
        return 'Removing unused Flatpak runtimes in a terminal window.'
    if a == 'drivers-install':
        terminal('Tweakr23 - drivers', 'sudo ubuntu-drivers install')
        return 'Installing recommended drivers in a terminal window. Restart afterwards.'
    if a == 'explorer':
        sh(['nautilus', '-q'], 10); return 'Files closed - it will open fresh next time.'
    if a == 'iconcache':
        sh(['update-desktop-database', os.path.join(HOME, '.local/share/applications')], 30)
        icons = os.path.join(HOME, '.local/share/icons/hicolor')
        if os.path.isdir(icons):
            sh(['gtk-update-icon-cache', '-f', '-t', icons], 30)
        if need_sudo():
            sh(['update-desktop-database'], 60, sudo=True)
        return 'App menu and icon caches refreshed.'
    if a == 'dns':
        code, _ = sh(['resolvectl', 'flush-caches'], 10, sudo=need_sudo())
        return 'DNS cache flushed.' if code == 0 else 'Could not flush DNS (is systemd-resolved running?).'
    if a == 'netreset':
        sudo_or_raise()
        sh(['systemctl', 'restart', 'NetworkManager'], 60, sudo=True)
        return 'NetworkManager restarted.'
    if a == 'cleanmgr':
        if has('baobab'):
            launch('baobab'); return 'Disk Usage Analyzer opened.'
        raise RuntimeError('Disk Usage Analyzer is not installed (sudo apt install baobab).')
    if a == 'regbackup':
        d = os.path.join(docs, 'Tweakr23 backups'); os.makedirs(d, exist_ok=True)
        f = os.path.join(d, f'dconf-{datetime.datetime.now():%Y%m%d-%H%M}.ini')
        with open(f, 'w') as fh:
            fh.write(sh(['dconf', 'dump', '/'], 30)[1])
        return f'Desktop settings saved to {f} (restore with: dconf load / < file)'
    if a == 'batteryreport':
        dev = next((ln for ln in sh(['upower', '-e'], 10)[1].split() if 'BAT' in ln), None)
        if not dev:
            raise RuntimeError('No battery found.')
        f = os.path.join(docs, 'battery-report.txt')
        with open(f, 'w') as fh:
            fh.write(sh(['upower', '-i', dev], 10)[1])
        launch('xdg-open', f)
        return f'Battery report saved to {f}'
    if a == 'wu-drivers':
        if has('software-properties-gtk'):
            launch('software-properties-gtk', '--open-tab=4'); return 'Opened Software & Updates > Additional Drivers.'
        raise RuntimeError('software-properties-gtk is not installed.')
    raise RuntimeError('Unknown action.')


# ---------------------------------------------------------------- dashboard
def get_dashboard():
    osr = re.search(r'PRETTY_NAME="?([^"\n]+)', read('/etc/os-release'))
    du = shutil.disk_usage('/')
    st = get_startup()
    devs = lspci_devices()
    return {'os': osr.group(1) if osr else 'Linux', 'build': os.uname().release, 'pc': socket.gethostname(),
            'uptimeHours': round(float(read('/proc/uptime').split()[0]) / 3600, 1), 'mem': mem_info(),
            'diskSize': du.total, 'diskFree': du.free, 'startupOn': sum(1 for x in st if x['enabled']),
            'startupSuggest': sum(1 for x in st if x['enabled'] and x['verdict'] == 'disable'),
            'problemDevices': sum(1 for d in devs if not d['driver'] and not QUIET_CLASSES.search(d['cls'])), 'power': power_profile()}


def quick_fix():
    ids = ['cache', 'tmp', 'browser'] + (['apt', 'snaps', 'journal', 'crash'] if need_sudo() else [])
    j = junk_clean(ids)
    r = list(j['report'])
    sh(['resolvectl', 'flush-caches'], 10, sudo=need_sudo()); r.append('DNS cache flushed')
    r.append(f'Broken launchers found: {len(get_broken_shortcuts()["items"])} (review them in Launcher Fix)')
    r.append(f'Autostart items worth turning off: {sum(1 for x in get_startup() if x["enabled"] and x["verdict"] == "disable")} (review them in Startup)')
    if not need_sudo():
        r.append('Tip: start with tweakr23.sh to include apt cache, old snaps and logs')
    return {'freed': j['freed'], 'report': r}


# ---------------------------------------------------------------- server
def ui_path():
    for c in (os.path.join(ROOT, '..', 'ui', 'index.html'), os.path.join(ROOT, 'ui', 'index.html'), os.path.join(ROOT, 'index.html')):
        if os.path.exists(c):
            return os.path.realpath(c)
    sys.exit('ui/index.html is missing - keep the folder structure from the download.')


UI = ui_path()

ROUTES = {
    ('GET', '/api/ping'): lambda b: {'ok': True},
    ('GET', '/api/mem'): lambda b: mem_info(),
    ('GET', '/api/dashboard'): lambda b: get_dashboard(),
    ('POST', '/api/quickfix'): lambda b: quick_fix(),
    ('GET', '/api/startup'): lambda b: {'items': get_startup()},
    ('POST', '/api/startup/set'): lambda b: (set_startup(b), {'ok': True})[1],
    ('GET', '/api/turbo'): lambda b: get_turbo(),
    ('POST', '/api/turbo/boost'): lambda b: turbo_boost(b),
    ('GET', '/api/junk/scan'): lambda b: junk_scan(),
    ('POST', '/api/junk/clean'): lambda b: junk_clean(b.get('ids', [])),
    ('GET', '/api/privacy'): lambda b: {'toggles': get_toggles('privacy')},
    ('POST', '/api/privacy/sweep'): lambda b: privacy_sweep(b.get('ids', [])),
    ('GET', '/api/tweaks'): lambda b: {'toggles': get_toggles('tweak'), 'power': power_profile()},
    ('POST', '/api/toggle'): lambda b: set_toggle(b),
    ('GET', '/api/extensions'): lambda b: get_extensions(),
    ('POST', '/api/extensions/open'): lambda b: (open_ext_page(b), {'ok': True})[1],
    ('POST', '/api/extensions/remove'): lambda b: remove_ext(b),
    ('GET', '/api/shortcuts'): lambda b: get_broken_shortcuts(),
    ('POST', '/api/shortcuts/remove'): lambda b: remove_shortcuts(b.get('paths', [])),
    ('GET', '/api/drivers'): lambda b: get_drivers(),
    ('GET', '/api/drivers/wu'): lambda b: find_driver_updates(),
    ('GET', '/api/health'): lambda b: get_health(),
    ('GET', '/api/volumes'): lambda b: get_volumes(),
    ('POST', '/api/volumes/action'): lambda b: volume_action(b),
    ('POST', '/api/system'): lambda b: {'message': system_action(b)},
    ('POST', '/api/open'): lambda b: (launch('xdg-open', b['url']) if re.match(r'^https://[\w.\-/?=&%#]+$', str(b.get('url', ''))) else None, {'ok': True})[1],
    ('POST', '/api/quit'): lambda b: (QUIT.set(), {'ok': True})[1],
}


class Handler(BaseHTTPRequestHandler):
    server_version = 'Tweakr23'

    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, ctype='application/json; charset=utf-8'):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self, method):
        u = urllib.parse.urlparse(self.path)
        if u.path == '/':
            if urllib.parse.parse_qs(u.query).get('t', [''])[0] != TOKEN:
                return self.send(403, b'Forbidden', 'text/plain')
            LAST_PING[0] = time.time()
            html = read(UI).replace('__TOKEN__', TOKEN).replace('__PLATFORM__', 'linux')
            return self.send(200, html.encode(), 'text/html; charset=utf-8')
        if self.headers.get('X-Token') != TOKEN:
            return self.send(403, {'error': 'Forbidden'})
        LAST_PING[0] = time.time()
        fn = ROUTES.get((method, u.path))
        if not fn:
            return self.send(404, {'error': f'No route {method} {u.path}'})
        body = {}
        n = int(self.headers.get('Content-Length') or 0)
        if n:
            try:
                body = json.loads(self.rfile.read(n) or b'{}')
            except Exception:
                body = {}
        if u.path != '/api/ping':
            print(f'[{time.strftime("%H:%M:%S")}] {method} {u.path}', flush=True)
        try:
            self.send(200, fn(body))
        except Exception as e:
            print(f'[{time.strftime("%H:%M:%S")}] ERROR {u.path}: {e}', flush=True)
            self.send(500, {'error': str(e)})

    def do_GET(self):
        self.handle_any('GET')

    def do_POST(self):
        self.handle_any('POST')


def open_panel(url):
    prof = os.path.join(os.environ.get('XDG_RUNTIME_DIR', '/tmp'), 'tweakr23-ui')
    for exe in ('google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser', 'brave-browser', 'microsoft-edge', 'vivaldi'):
        if has(exe):
            launch(exe, f'--app={url}', f'--user-data-dir={prof}', '--window-size=1320,880', '--no-first-run', '--no-default-browser-check')
            return
    launch('xdg-open', url)                             # Firefox or anything else: opens as a normal tab


def main():
    if UID == 0:
        sys.exit('Run Tweakr23 as your normal user (use ./tweakr23.sh) - it asks for admin rights itself.')
    try:
        restore_fsck_counts()
    except Exception:
        pass
    srv = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    port = srv.server_address[1]
    url = f'http://127.0.0.1:{port}/?t={TOKEN}'
    print('\n  \033[30;46m TWEAKR23 \033[0m  by Tech Merlin\n  Panel running. Close this window or press Quit in the panel to stop.\n', flush=True)
    if '--no-browser' in sys.argv:
        print(f'  Open: {url}\n', flush=True)
    else:
        open_panel(url)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        while not QUIT.is_set():
            if time.time() - LAST_PING[0] > IDLE_EXIT:
                print('Panel closed - shutting down.')
                break
            QUIT.wait(1)
    except KeyboardInterrupt:
        pass
    time.sleep(0.3)
    srv.shutdown()


if __name__ == '__main__':
    main()
