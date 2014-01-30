aws-backups
===========

Automate AWS backups and snapshots

1. Create snapshots of EC2 instances tagged as "backup" = 1
2. Copy snapshots across different regions
3. Create volume images of volumes tagged as "backup" = 1
4. Copy volume images across different regions
5. Tag copied snapshots and images with expiration dates when they will be automatically deleted
6. Automate using any message queuing job service



