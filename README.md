# selinux-volume-labels

Lab for my proposed lightning talk "Before You Disable SELinux: Container Volume Labels and Kubernetes 1.37".

selinux-volume-lab.sh runs each demo step and saves the output to a log file in your home directory.
logs/rocky-10.log is the output from a Rocky Linux 10.2 VM.

Run it on a test machine with SELinux enforcing:

    bash selinux-volume-lab.sh

It uses sudo. It creates a test directory in your home directory and a 400 MB disk image in /var/tmp,
mounts the image on /mnt/selinux-lab-a and /mnt/selinux-lab-b, and removes all of it at the end.
Tested with Podman only.
