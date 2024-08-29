# kvm-borg
A script to handle backing up KVM virtual machines to a borg repository.

The code is short and basically self explanatory.

kvm-borg performs VM shutdown and backs up complete virtual machines to an existing borg backup repository. It can backup physical pass-through disks to the VMs, and even multiple partitions inside those disks.

This was developed to solve a particular need I had, and as such, it has references to tools like ntfsclone, used in situations where physical disks or partitions are NTFS formatted, to ensure they are cloned correctly.

You're free to do whatever you want with this code. I will be liable for no unintended consequences of doing so. Send me a message if you find it useful.
