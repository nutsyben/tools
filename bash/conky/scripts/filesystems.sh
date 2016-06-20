#!/bin/bash

. functions/common 2> /dev/null


# All of our file system parsing revolves around parsing /proc/1/mountinfo.
# If this file cannot be reached (I cannot imagine that it would not exist altogether), then do not bother continuing.
# Do not print an error if this is the case.
[ -r "/proc/1/mountinfo" ] || exit 0

#############
# Inventory #
#############

# Note: Debian-based (e.g. Ubuntu 12.04) and RHEL-based (e.g. CentOS 6, Fedora 23) have slightly different formats for /proc/1/mountinfo.
#   RHEL has an extra field between some of the fields that we are looking under.
# In order, we are after the following fields:
#   Mount bind source (will just be '/' otherwise).
#   Mount point, file system is mounted to here.
#   File system type
#   Device file or network path of file system
#   Options
if [ "$(head -n1 /proc/1/mountinfo | grep -o " " | wc -l)" -eq 10 ]; then
    # RHEL-observed format.
    cut_fields="4,5,9,10,11"
else
    # Debian-observed format
    cut_fields="4,5,8,9,10"
fi

# Basic file systems: / and /home (if separate from /)
root_file_system=$(cut -d' ' -f $cut_fields < /proc/1/mountinfo | grep "/ / " | sed 's/ /\\236/g')

# If our home directory is within /home, apply an extra sed expression
if [[ "$HOME" =~ ^/home ]]; then
  # If my home directory is in a partition mounted on /home, then I want it to be displayed as simply '~'
  # The extra expression will cause this script to replace part of the displayed file path with '~' before it is displayed.
  home_file_system=$(cut -d' ' -f $cut_fields < /proc/1/mountinfo | grep " /home " | sed -e "s| /home | $HOME |g" -e 's/ /\\236/g')
else
  home_file_system=$(cut -d' ' -f $cut_fields < /proc/1/mountinfo | grep " /home " | sed 's/ /\\236/g')
fi

## Dynamically include other significant mounted file systems.
# File system pattern shows the following mounted file system types:
#   - tmpfs
#   - Any fuse file system
#   - ext*
#   - cifs (Samba) file systems
#   - nfs
#   - File systems containing 'fat'
#   - NTFS
#   - UDF

# Out of the above listed file systems, mount point pattern excludes the following mountpoints:
#   - /, as this path is handled separately
#   - /home (or parent file system), as this path is handled separately.
#   - Anything mounted to or within /dev, /sys, /tmp, or /boot
#   - Anything mounted directly onto /run
#   - /run/cmanager/fs and /run/lock, two tmpfs directories on Ubuntu systems
#   - gvfsd file system at /run/user/$UID/gvfs
# This should cover all other system-specific, temporary (USB drives, SD cards), or network, network file systems, etc.
extra_file_systems="$(cut -d' ' -f $cut_fields < /proc/1/mountinfo | egrep ' (ext.|tmpfs|cifs|nfs4?|vfat|iso9660|fuse\.[^\ ]*|ntfs(\-3g)?|btrfs|fuseblk|udf) ' | egrep -v '^/ / |(/ ((/dev|/sys|/boot|/tmp)|/run |/run/user/\d?|/gvfs|/run/cmanager/fs|/run/lock|/home | / / ))' | sort -t' ' -k1,2 | sed -e 's/ /\\236/g' -e 's/\$/\$\$/g')"

##########
# Header #
##########

printf "\${color #${colour_local_path}}\${font Neuropolitical:size=16:bold}File Systems\$font\$color\$hr\n"

# Cycle through all collected file systems, and print information.
for raw_fs_data in ${root_file_system} ${home_file_system} ${extra_file_systems}; do

    # Reverse encoding
    fs_data="$(sed 's/\\236/ /g' <<< "$raw_fs_data")"

    # FS Stored in /proc/1/mountinfo
    fs_bind_location=$(cut -d' ' -f1  <<< "${fs_data}" | sed 's/\\040/ /g' )
    fs=$(cut -d' ' -f2  <<< "${fs_data}" | sed 's/\\040/ /g' )
    fs_type=$(cut -d' ' -f3 <<< "${fs_data}")
    fs_source=$(cut -d' ' -f4  <<< "${fs_data}" | sed 's/\\040/ /g' )
    fs_options=$(cut -d' ' -f5  <<< "${fs_data}" | sed 's/\\040/ /g' )

    # Substitute home directory path for '~' and shorten.
    fs_title="$(shorten_string "$(sed "s|^$HOME|\\~|g" <<< "$fs")" "$((36-$(expr length "$fs_type")))")"

    # If the target directory does not even exist, do not bother continuing through the loop.
    # Made for static systems, since some target file systems are dynamically listed off of find command.
    [ -d "${fs}" ] || continue

    # Special colour for network-based file systems.
    if egrep -qm1 "cifs|nfs|fuse\.obexfs" <<< "${fs_type}"; then
        fs_colour=${colour_network}
    else
        fs_colour=${colour_local_path}
    fi

    printf  "\${color #${fs_colour}}${fs_title}\$color (\${color red}\${fs_type ${fs}}\$color)\$color\n"
    
    if ! grep -q "^/$" <<< "${fs_bind_location}" && ! [[ "${fs_type}" =~ "cifs" ]]; then
        # Avoid redundant information by treating bind mounts differently.

        # CIFS for bind mounts is still quite a bit of a pickle.
        # Nothing in a `findmnt -nD` call or /proc/1/mountinfo line for a particular mount reveals its true origin location.
        # I was tempted to try to look for "unambiguous bind mounts" (e.g. if the only other mount of the share is to a higher level),
        #     but another issue put all the necessary nails in the proverbial coffin:
        # It is also not possible to tell a CIFS bind mount apart from a direct mount to a deeper folder in the share
        #     (for example, directly mounting //10.11.12.13/share/inner would appear as a false positive for a bind mount).

        # Until another option shows up to solve the above hurdles, I will NOT be covering CIFS bind mounts.
        # Will just have to suffer through redundant information if we run across this edge case.

        printf " Bind: \${color #${fs_colour}}%s\$color\n" "$(shorten_string "${fs_bind_location}" 32)"

    elif [[ "$fs_type" != "-" ]]; then
        # If df/findmnt reports disk usage as a "-", then we will not be able to get these numbers through conky either.
        # If the file system is not supported by conky, do not try to print usage information.

        # If the file system is not a far-away network file system, then show the usage bar.
        # Far-away file systems could cause conky to seize up, especially if bandwidth is taxed.
        # For the moment, I am using the presence of the "nointr" flag on a mount (currently unimplemented in SAMBA) to symbolize a faraway connection.
        # TODO: Find a more reliable marker.
        # I am considering shifting to the intr/nointr flags, which are NYI at the moment according to https://www.samba.org/samba/docs/man/manpages-3/mount.cifs.8.html
        if ! ( ( [[ "${fs_type}" =~ "cifs" ]] || [[ "${fs_type}" =~ "nfs" ]] ) && grep -qw "nointr" <<< "$fs_options" ) ; then
            printf " Usage: \${fs_used ${fs}}/\${fs_size ${fs}} - \${fs_used_perc ${fs}}%% \${fs_bar 6 ${fs}}\n"
        else
            extra_text=" (far)"
        fi

        # Print remote location for CIFS.
        if [[ "${fs_type}" =~ "cifs" ]]; then

                remote_point="$(shorten_string "${fs_source}" 31)"

                printf " Share%s: \${color #${colour_network}}%s\$color\n" "$extra_text" "$(shorten_string ${remote_point} 23)"
        fi
        # TODO: Do similarly to print the remote location for NFS.

        unset extra_text
    fi
done

