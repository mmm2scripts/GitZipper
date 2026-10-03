# GitZipper API - setup without root

Needs only Python 3.8+ (check: `python3 --version`). No pip, no packages.

## 1. Install
```bash
mkdir -p ~/gitzipper && cd ~/gitzipper
# copy gitzipper_api.py here (scp, git clone, or paste)
chmod +x gitzipper_api.py
```

## 2. Run (port must be above 1024)
```bash
API_KEY="choose-a-long-random-string" PORT=8787 python3 gitzipper_api.py
curl http://localhost:8787/health        # -> {"ok": true}
```

## 3. Keep it running without root
Pick one:
```bash
# a) background with nohup
API_KEY="..." PORT=8787 nohup python3 ~/gitzipper/gitzipper_api.py > ~/gitzipper/log.txt 2>&1 &

# b) tmux / screen
tmux new -s gitzipper    # run the command, then Ctrl-B D

# c) start at reboot (user crontab: crontab -e)
@reboot API_KEY="..." PORT=8787 python3 $HOME/gitzipper/gitzipper_api.py >> $HOME/gitzipper/log.txt 2>&1
```
(systemd `--user` units also work if your host enables lingering.)

## 4. HTTPS (iOS blocks plain http)
The app needs an https URL. Without root:
- Hosting panel / existing domain: point a reverse proxy or subdomain to port 8787.
- No domain: run a Cloudflare quick tunnel from your home directory:
  `./cloudflared tunnel --url http://localhost:8787` -> gives a https://xxxx.trycloudflare.com URL
  (download the cloudflared binary from Cloudflare's GitHub releases; no install needed).

## 5. Connect the app
GitZipper -> Settings -> Upload server: paste the https URL and the API key.
ZIP uploads then go through your server. Leave the URL empty to upload directly.

Security: your GitHub token is sent to the server on each upload (never stored). Use only a server you control, with HTTPS and an API key.
Limits: zip up to MAX_MB (default 300). Set env MAX_MB to change.
