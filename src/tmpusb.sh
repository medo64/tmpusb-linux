#!/bin/bash

SCRIPT_NAME=`basename $0`
if [ -t 1 ]; then
    ANSI_RESET="$(tput sgr0)"
    ANSI_UNDERLINE="$(tput smul)"
    ANSI_ERROR="`[ $(tput colors) -ge 16 ] && tput setaf 9 || tput setaf 1 bold`"
    ANSI_WARNING="`[ $(tput colors) -ge 16 ] && tput setaf 11 || tput setaf 3 bold`"
    ANSI_VERBOSE="`[ $(tput colors) -ge 16 ] && tput setaf 12 || tput setaf 4 bold`"
fi

MOUNT_DIRECTORY="/tmpusb"

TMPUSB_DEVICE=""
NEW_LABEL=""
MOUNT=0
UNMOUNT=0
VERBOSE=0

while getopts ":d:muv" OPT; do
    case $OPT in
        d)  TMPUSB_DEVICE=$OPTARG ;;
        m)  MOUNT=1 ;;
        u)  UNMOUNT=1 ;;
        v)  VERBOSE=$((VERBOSE+1)) ;;

        *)  echo
            echo    "  SYNOPSIS"
            echo -e "  $SCRIPT_NAME [${ANSI_UNDERLINE}-d device${ANSI_RESET}] [${ANSI_UNDERLINE}-m${ANSI_RESET}] [${ANSI_UNDERLINE}-u${ANSI_RESET}] [${ANSI_UNDERLINE
}label${ANSI_RESET}]"
            echo
            echo -e "    ${ANSI_UNDERLINE}-d device${ANSI_RESET}"
            echo    "    Device to use."
            echo
            echo -e "    ${ANSI_UNDERLINE}-m${ANSI_RESET}"
            echo    "    Mounts device under /tmpusb/."
            echo
            echo -e "    ${ANSI_UNDERLINE}-u${ANSI_RESET}"
            echo    "    Unmounts device."
            echo
            echo -e "    ${ANSI_UNDERLINE}-v${ANSI_RESET}"
            echo    "    Shows debug information."
            echo
            echo -e "    ${ANSI_UNDERLINE}label${ANSI_RESET}"
            echo    "    Sets the label."
            echo
            echo    "  DESCRIPTION"
            echo    "  Shows and optionally sets the label."
            echo    "  Unmounting is done before label writing while mounting is done after label writing has taken place."
            echo    "  Label writing, mounting, and unmounting are done only if a single device is found or specified."
            echo
            echo    "  The following labels have a special meaning:"
            echo    "  * ARM   - activates TmpUsb on next loss of power"
            echo    "  * ARMED - activates TmpUsb immediately"
            echo
            echo    "  You can find additional commands and instructions at https://medo64.com/tmpusb/"
            echo
            echo    "  SAMPLES"
            echo    "  $0"
            echo    "  $0 Armed"
            echo    "  $0 -d da0s1 Armed"
            echo    "  $0 -d da0s1 -m"
            echo
            exit 255
        ;;
    esac
done
shift $((OPTIND-1))

if [[ "$2" != "" ]]; then
    echo -e "${ANSI_ERROR}$SCRIPT_NAME: too many arguments!${ANSI_RESET}" >&2
    exit 255
fi

NEW_LABEL=$1
if [[ ${#NEW_LABEL} -gt 11 ]]; then
    echo -e "${ANSI_ERROR}Label length cannot exceed 11 characters!${ANSI_RESET}" >&2
    exit 1
fi

trap "echo -ne '${ANSI_RESET}' ; rm $TEMP_SECTOR_FILE 2> /dev/null" EXIT SIGHUP SIGINT SIGTERM

if [[ "$TMPUSB_DEVICE" == "" ]]; then
    if command -v geom &> /dev/null; then  # BSD
        DEVICES=`geom disk status -s | awk '{print $1}'`
    else
        DEVICES=`fdisk --list 2>/dev/null | grep "^Disk /dev/" | grep -v ' /dev/zd[0-9]' | cut -d: -f1 | rev | cut -d/ -f1 | rev | sort`
    fi

    TMPUSB_DEVICE_COUNT=0
    if [[ $VERBOSE -gt 0 ]]; then echo -e "${ANSI_VERBOSE}Found devices:"; fi
    for DEVICE in $DEVICES; do
        if [[ $VERBOSE -gt 0 ]]; then echo -n "* $DEVICE"; fi
        if [ -e /dev/$DEVICE ]; then
            HEX_SERIAL=`dd if=/dev/$DEVICE bs=1 skip=551 count=4 2>/dev/null | hexdump -n 4 -e '4/1 "%02X"'`
            if [[ "$HEX_SERIAL" == "4D65646F" ]]; then
                HEX_FAT_TYPE=`dd if=/dev/$DEVICE bs=1 skip=566 count=8 2>/dev/null | hexdump -n 8 -e '8/1 "%02X"'`
                if [[ "$HEX_FAT_TYPE" == "4641543132202020" ]]; then
                    if [[ $VERBOSE -gt 0 ]]; then echo -n " (TmpUsb)"; fi
                    TMPUSB_DEVICE_COUNT=$((TMPUSB_DEVICE_COUNT+1))
                    TMPUSB_DEVICES="$TMPUSB_DEVICES $DEVICE"
                else
                    if [[ $VERBOSE -gt 0 ]]; then echo -n " (unrecognized file systen $HEX_FAT_TYPE)"; fi
                fi
            else
                if [[ $VERBOSE -gt 0 ]]; then echo -n " (unrecognized serial number $HEX_SERIAL)"; fi
            fi
        else
            if [[ $VERBOSE -gt 0 ]]; then echo -n " (device not found)"; fi
        fi
        if [[ $VERBOSE -gt 0 ]]; then echo; fi
    done
    if [[ $VERBOSE -gt 0 ]]; then echo -ne "${ANSI_RESET}"; fi

    TMPUSB_DEVICES=`echo $TMPUSB_DEVICES | xargs`
    if [[ $TMPUSB_DEVICE_COUNT -eq 0 ]]; then
        echo -e "${ANSI_ERROR}No TmpUsb device found!${ANSI_RESET}" >&2
        exit 1
    elif [[ $TMPUSB_DEVICE_COUNT -eq 1 ]]; then
        TMPUSB_DEVICE=`echo $TMPUSB_DEVICES`
    else
        TMPUSB_DEVICE=`echo $TMPUSB_DEVICES | awk '{print $1}'`
        echo -e "${ANSI_WARNING}Multiple TmpUsb devices found: $TMPUSB_DEVICES; using $TMPUSB_DEVICE!${ANSI_RESET}" >&2
    fi
fi

if [[ -e "/dev/${TMPUSB_DEVICE}s1" ]]; then  # BSD
    TMPUSB_DEVICE_PARTITION="/dev/${TMPUSB_DEVICE}s1"
elif [[ -e "/dev/${TMPUSB_DEVICE}1" ]]; then  # Linux
    TMPUSB_DEVICE_PARTITION="/dev/${TMPUSB_DEVICE}1"
else
    echo -e "${ANSI_ERROR}No TmpUsb partition found!${ANSI_RESET}" >&2
    exit 1
fi

if [[ $UNMOUNT -gt 0 ]]; then
    if [[ $VERBOSE -gt 0 ]]; then echo -e "${ANSI_VERBOSE}Unmounting device ${TMPUSB_DEVICE_PARTITION}${ANSI_RESET}"; fi
    MOUNT_DIRECTORY_CURRENT=`mount | grep "^${TMPUSB_DEVICE_PARTITION}" | cut -d' ' -f3`
    if [[ "$MOUNT_DIRECTORY_CURRENT" != "" ]]; then
        if [[ $VERBOSE -gt 1 ]]; then echo -e "${ANSI_VERBOSE}Removing mount directory $MOUNT_DIRECTORY_CURRENT${ANSI_RESET}"; fi
        UMOUNT_RESULT=`umount ${TMPUSB_DEVICE_PARTITION} 2>&1`
        if [[ $? -ne 0 ]]; then
            echo -e "${ANSI_ERROR}$UMOUNT_RESULT${ANSI_RESET}"
        fi
        rmdir "$MOUNT_DIRECTORY_CURRENT" 2> /dev/null
    else
        echo -e "${ANSI_WARNING}Mount point for ${TMPUSB_DEVICE_PARTITION} not found.${ANSI_RESET}" >&2
    fi
fi

if [[ "$NEW_LABEL" != "" ]]; then
    MOUNT_DIRECTORY_CURRENT=`mount | grep "^${TMPUSB_DEVICE_PARTITION}" | cut -d' ' -f3`
    if [[ "$MOUNT_DIRECTORY_CURRENT" != "" ]]; then
        echo "$MOUNT_DIRECTORY_CURRENT"
        echo -e "${ANSI_ERROR}Cannot write label to currently mounted device ${TMPUSB_DEVICE_PARTITION}!${ANSI_RESET}" >&2
        exit 1
    fi

    if [[ $VERBOSE -gt 0 ]]; then echo -e "${ANSI_VERBOSE}Writing $NEW_LABEL to $TMPUSB_DEVICE${ANSI_RESET}"; fi

    TEMP_SECTOR_FILE=`mktemp /tmp/$SCRIPT_NAME.XXXXXXXX`
    dd if=/dev/$TMPUSB_DEVICE bs=512 skip=3 count=1 of=$TEMP_SECTOR_FILE 2> /dev/null
    if [[ $VERBOSE -gt 2 ]]; then
        echo -e "${ANSI_VERBOSE}* Sector content before:"
        cat $TEMP_SECTOR_FILE | hexdump -Cv | head -n 4 | sed -e 's/^/  /'
        echo -ne "${ANSI_RESET}"
    fi

    echo -n "           " | dd of=$TEMP_SECTOR_FILE count=11 conv=notrunc 2> /dev/null
    echo -n "$NEW_LABEL" | dd of=$TEMP_SECTOR_FILE count=${#NEW_LABEL} conv=notrunc 2> /dev/null
    if [[ $VERBOSE -gt 2 ]]; then
        echo -e "${ANSI_VERBOSE}* Sector content after:"
        cat $TEMP_SECTOR_FILE | hexdump -Cv | head -n 4 | sed -e 's/^/  /'
        echo -ne "${ANSI_RESET}"
    fi

    dd if=$TEMP_SECTOR_FILE bs=512 seek=3 count=1 of=/dev/$TMPUSB_DEVICE 2> /dev/null
    if [[ $? -gt 0 ]]; then
        echo -e "${ANSI_ERROR}Cannot write label to /dev/${TMPUSB_DEVICE}!${ANSI_RESET}" >&2
        exit 1
    fi
fi

if [[ $MOUNT -gt 0 ]]; then
    if [[ $VERBOSE -gt 0 ]]; then echo -e "${ANSI_VERBOSE}Mounting device ${TMPUSB_DEVICE_PARTITION} into $MOUNT_DIRECTORY${ANSI_RESET}"; fi
    rmdir $MOUNT_DIRECTORY 2> /dev/null
    if [ -d "$MOUNT_DIRECTORY" ]; then
        echo -e "${ANSI_ERROR}Directory $MOUNT_DIRECTORY already present and not empty!${ANSI_RESET}" >&2
        exit 1
    fi
    mkdir $MOUNT_DIRECTORY
    if command -v mount_msdosfs &> /dev/null; then  # BSD
        mount_msdosfs ${TMPUSB_DEVICE_PARTITION} $MOUNT_DIRECTORY
    else
        mount -t vfat -o rw  ${TMPUSB_DEVICE_PARTITION} $MOUNT_DIRECTORY
    fi
fi

LABEL=`dd if=/dev/$TMPUSB_DEVICE bs=512 skip=3 count=1 2> /dev/null | hexdump -n11 -e '11/1 "%c"' | tr -d '[[:space:]]'`
MOUNTED_AT=`mount | grep "^${TMPUSB_DEVICE_PARTITION}" | cut -d' ' -f3`

echo -n "/dev/$TMPUSB_DEVICE $LABEL"
if [[ "$MOUNTED_AT" != "" ]]; then
    echo -n " ($MOUNTED_AT)"
fi
echo

if [[ $VERBOSE -gt 2 ]]; then
    echo -e "${ANSI_VERBOSE}* Sector content:"
    dd if=/dev/$TMPUSB_DEVICE bs=512 skip=3 count=1 2> /dev/null | hexdump -Cv | head -n 4 | sed -e 's/^/  /'
    echo -ne "${ANSI_RESET}"
fi
