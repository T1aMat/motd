# Spookdev-MOTD (edited by Skrepysh)

![MOTD-Screen](https://github.com/T1aMat/motd/blob/master/screenshot.png)

Custom MOTD scripts based off of PlexMOTD. This is running on Ubuntu or Debian, and the scripts are split into manageable chunks.

## Installation
1. Run the motd install script: 
 - For Ubuntu:
```
curl -L https://raw.githubusercontent.com/T1aMat/motd/refs/heads/master/scripts/ubuntu.sh > motd_install.sh && sudo chmod +x motd_install.sh && sudo ./motd_install.sh
```
- For Debian:
```
curl -L https://raw.githubusercontent.com/T1aMat/motd/refs/heads/master/scripts/debian.sh > motd_install.sh && sudo chmod +x motd_install.sh && sudo ./motd_install.sh
```
2. Change `/etc/update-motd.d/colors.txt` to your liking.
3. Change services in `/etc/update-motd.d/09-services` to suit your needs.
4. Optionally change `PrintLastLog` to `no` in `/etc/ssh/sshd_config`.
