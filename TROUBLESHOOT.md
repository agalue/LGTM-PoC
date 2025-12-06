If you cannot create the second cluster, try the following:
```bash
sudo sysctl fs.inotify.max_user_watches=524288
sudo sysctl fs.inotify.max_user_instances=512
```

Enable Debug for Ztunnel
```bash
istioctl zc log --level ztunnel=debug,hickory_server::server::server_future=debug,ztunnel::dns=trace,dns=debug
```
