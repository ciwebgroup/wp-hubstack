# Bind Mounts Configuration for jailbird.sh

The `jailbird.sh` script supports two methods for configuring bind mounts: **command-line arguments** and **configuration files**.

## Command-Line Method

Use space-separated mount pairs directly in the command:

```bash
sudo ./jailbird.sh -u myftpuser -b '/var/www/site1::site1 /var/www/site2::site2'
```

## File-Based Method (Recommended for Multiple Mounts)

Create a text file with one mount per line and pass the file path:

```bash
sudo ./jailbird.sh -u myftpuser -b /path/to/mounts.txt
```

## File Format

### Basic Format
Each line should contain a source and destination path separated by `::`:
```
/absolute/source/path::relative_destination_name
```

### Comments and Empty Lines
- Lines starting with `#` or `//` are treated as comments
- Empty lines are ignored
- Leading/trailing whitespace is automatically trimmed

### Example Configuration File
```bash
# Web directories
/var/www/website1::site1
/var/www/website2::site2
/var/www/blog::blog

// Shared resources
/opt/shared-files::shared
/data/user-uploads::uploads

# Development directories
/home/developer/projects::projects
/var/log/applications::logs
```

## Path Requirements

### Source Paths (Left side of `::`)
- Must be **absolute paths** (start with `/`)
- Must exist or be creatable by the script
- Will be owned by the FTP user after setup

### Destination Paths (Right side of `::`)
- Must be **relative paths** (no leading `/`)
- Will be created inside the FTP user's chroot jail
- Accessible as `/home/ftpuser/destination_name`

## Validation and Error Handling

The script automatically:
- ✅ Validates the `::` separator format
- ✅ Checks for empty source or destination paths
- ✅ Converts absolute destination paths to relative ones
- ✅ Skips invalid lines with warnings
- ✅ Reports parsing statistics
- ❌ Fails if no valid mounts are found

## Usage Examples

### 1. Full Setup with File
```bash
# Create your mounts configuration
echo "/var/www/mysite::website" > /tmp/mounts.txt
echo "/data/uploads::uploads" >> /tmp/mounts.txt

# Run the setup
sudo ./jailbird.sh -u webuser -b /tmp/mounts.txt --generate-password
```

### 2. Add Mounts to Existing User
```bash
# Create additional mounts file
cat > /tmp/additional-mounts.txt << EOF
# New directories to add
/opt/backups::backups
/var/log/nginx::logs
EOF

# Add only the new mounts
sudo ./jailbird.sh -u webuser -b /tmp/additional-mounts.txt --add-mounts-only
```

### 3. Dry Run Testing
```bash
# Test your configuration without making changes
sudo ./jailbird.sh -u testuser -b /path/to/mounts.txt --dry-run
```

## File Access After Setup

Once configured, the FTP user will see the mounted directories in their home directory:

```
/home/ftpuser/
├── uploads/          # writable directory for FTP uploads
├── site1/           # mounted from /var/www/website1
├── site2/           # mounted from /var/www/website2
├── shared/          # mounted from /opt/shared-files
└── logs/            # mounted from /var/log/applications
```

## Best Practices

1. **Use descriptive destination names** that make sense to FTP users
2. **Group related mounts** with comments in your configuration file
3. **Test with `--dry-run`** before applying changes
4. **Keep a backup** of your mounts configuration file
5. **Use absolute paths** for source directories
6. **Use relative paths** for destination directories

## Troubleshooting

### Common Issues

**"No valid bind mounts found"**
- Check that your file contains valid `source::destination` lines
- Ensure the file is readable
- Verify the file format matches the examples

**"Missing '::' separator"**
- Each mount line must contain exactly one `::` separator
- Check for typos like `:` or `:::` or `;;`

**"Absolute destination path"**
- Destination paths should not start with `/`
- The script will automatically convert them, but it's better to fix the file

### Debug Mode
Use `--dry-run` to see what the script would do without making changes:
```bash
sudo ./jailbird.sh -u testuser -b /path/to/mounts.txt --dry-run
```

This will show you:
- How many mounts were parsed
- What each mount will look like
- Any validation warnings or errors 