#!/bin/bash

SCRIPT_NAME=`basename $0`
if [ -t 1 ]; then
    ANSI_RESET="$(tput sgr0)"
    ANSI_UNDERLINE="$(tput smul)"
    ANSI_RED="`[ $(tput colors) -ge 16 ] && tput setaf 9 || tput setaf 1 bold`"
    ANSI_YELLOW="`[ $(tput colors) -ge 16 ] && tput setaf 11 || tput setaf 3 bold`"
    ANSI_BLUE="`[ $(tput colors) -ge 16 ] && tput setaf 12 || tput setaf 4 bold`"
    ANSI_CYAN="`[ $(tput colors) -ge 16 ] && tput setaf 14 || tput setaf 6 bold`"
    ANSI_WHITE="`[ $(tput colors) -ge 16 ] && tput setaf 15 || tput setaf 7 bold`"
    ANSI_TEAL="$(tput setaf 6)"
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
            echo -e "  $SCRIPT_NAME [${ANSI_UNDERLINE}-d device${ANSI_RESET}] [${ANSI_UNDERLINE}-m${ANSI_RESET}] [${ANSI_UNDERLINE}-u${ANSI_RESET}] [${ANSI_UNDERLINE}label${ANSI_RESET}]"
            echo
            echo -e "    ${ANSI_UNDERLINE}-d device${ANSI_RESET}"
            echo    "    Device to use."
            echo
            echo -e "    ${ANSI_UNDERLINE}-m${ANSI_RESET}"
            echo    "    Mount device under /tmpusb/."
            echo
            echo -e "    ${ANSI_UNDERLINE}-u${ANSI_RESET}"
            echo    "    Unmount device."
            echo
            echo -e "    ${ANSI_UNDERLINE}-v${ANSI_RESET}"
            echo    "    Show vebose information."
            echo
            echo -e "    ${ANSI_UNDERLINE}label${ANSI_RESET}"
            echo    "    Label to set."
            echo
            echo    "  DESCRIPTION"
            echo    "  Shows and optionally sets the label."
            echo    "  Unmounting is done before label writing while mounting is done after label writing has taken place."
            echo    "  Label writing, mounting, and unmounting are done only if a single device is found or specified."
            echo
            echo    "  The following labels have a special meaning:"
            echo    "  * ARMED - activates TmpUsb self-erase capability"
            echo
            echo    "  You can find additional commands and instructions at https://medo64.com/tmpusb/"
            echo
            echo    "  SAMPLES"
            echo    "  $0"
            echo    "  $0 Armed"
            echo    "  $0 -d da0s1 ARMED"
            echo    "  $0 -d da0s1 -m"
            echo
            exit 255
        ;;
    esac
done
shift $((OPTIND-1))

if [[ "$2" != "" ]]; then
    echo -e "${ANSI_RED}$SCRIPT_NAME: too many arguments!${ANSI_RESET}" >&2
    exit 255
fi

NEW_LABEL=$1
if [[ ${#NEW_LABEL} -gt 11 ]]; then
    echo -e "${ANSI_RED}Label length cannot exceed 11 characters!${ANSI_RESET}" >&2
    exit 1
fi

trap "echo -ne '${ANSI_RESET}' ; rm $TEMP_SECTOR_FILE 2> /dev/null" EXIT SIGHUP SIGINT SIGTERM


# Find all devices

if command -v geom &> /dev/null; then  # BSD
    DEVICES=`geom disk status -s | awk '{print $1}'`
else
    DEVICES=`fdisk --list 2>/dev/null | grep "^Disk /dev/" | grep -v ' /dev/zd[0-9]' | cut -d: -f1 | rev | cut -d/ -f1 | rev | sort`
fi

TMPUSB_DEVICE_COUNT=0
if [[ $VERBOSE -ge 3 ]]; then echo -e "${ANSI_BLUE}Found devices:"; fi
for DEVICE in $DEVICES; do
    if [ -e /dev/$DEVICE ]; then
        HEX_SERIAL=`dd if=/dev/$DEVICE bs=1 skip=551 count=4 2>/dev/null | hexdump -n 4 -e '4/1 "%02X"'`
        if [[ "$HEX_SERIAL" == "4D65646F" ]]; then
            HEX_FAT_TYPE=`dd if=/dev/$DEVICE bs=1 skip=566 count=8 2>/dev/null | hexdump -n 8 -e '8/1 "%02X"'`
            if [[ "$HEX_FAT_TYPE" == "4641543132202020" ]]; then
                if [[ $VERBOSE -ge 3 ]]; then echo  "  $DEVICE (TmpUsb)"; fi
                TMPUSB_DEVICE_COUNT=$((TMPUSB_DEVICE_COUNT+1))
                TMPUSB_DEVICES="$TMPUSB_DEVICES $DEVICE"
            else
                if [[ $VERBOSE -ge 4 ]]; then echo  "  $DEVICE (unrecognized file system: $HEX_FAT_TYPE)"; fi
            fi
        else
            if [[ $VERBOSE -ge 4 ]]; then echo "  $DEVICE (unrecognized serial number: $HEX_SERIAL)"; fi
        fi
    else
        if [[ $VERBOSE -ge 4 ]]; then echo "  $DEVICE (not connected)"; fi
    fi
done
if [[ $VERBOSE -ge 3 ]]; then echo -ne "${ANSI_RESET}"; fi

TMPUSB_DEVICES=`echo $TMPUSB_DEVICES | xargs`
if [[ $TMPUSB_DEVICE_COUNT -eq 0 ]]; then
    echo -e "${ANSI_RED}No TmpUsb device found!${ANSI_RESET}" >&2
    exit 1
fi


# Figure out which device to use

if [[ "$TMPUSB_DEVICE" == "" ]]; then
    if [[ $TMPUSB_DEVICE_COUNT -eq 1 ]]; then
        TMPUSB_DEVICE="$TMPUSB_DEVICES"
    else
        TMPUSB_DEVICE=`echo $TMPUSB_DEVICES | awk '{print $1}'`
        echo -e "${ANSI_YELLOW}Multiple TmpUsb devices found: $TMPUSB_DEVICES; using ${ANSI_CYAN}$TMPUSB_DEVICE${ANSI_YELLOW}!${ANSI_RESET}" >&2
    fi
fi


# Find if partition is present

if [[ -e "/dev/${TMPUSB_DEVICE}s1" ]]; then  # BSD
    TMPUSB_DEVICE_PARTITION="/dev/${TMPUSB_DEVICE}s1"
elif [[ -e "/dev/${TMPUSB_DEVICE}1" ]]; then  # Linux
    TMPUSB_DEVICE_PARTITION="/dev/${TMPUSB_DEVICE}1"
else
    echo -e "${ANSI_RED}No TmpUsb partition found!${ANSI_RESET}" >&2
    exit 1
fi


# Unmount

if [[ $UNMOUNT -gt 0 ]]; then
    if [[ $VERBOSE -ge 2 ]]; then echo -e "${ANSI_BLUE}Unmounting device ${TMPUSB_DEVICE_PARTITION}${ANSI_RESET}"; fi
    MOUNT_DIRECTORY_CURRENT=`mount | grep "^${TMPUSB_DEVICE_PARTITION}" | cut -d' ' -f3`
    if [[ "$MOUNT_DIRECTORY_CURRENT" != "" ]]; then
        if [[ $VERBOSE -ge 3 ]]; then echo -e "${ANSI_BLUE}Removing mount directory $MOUNT_DIRECTORY_CURRENT${ANSI_RESET}"; fi
        UMOUNT_RESULT=`umount ${TMPUSB_DEVICE_PARTITION} 2>&1`
        if [[ $? -ne 0 ]]; then
            echo -e "${ANSI_RED}$UMOUNT_RESULT${ANSI_RESET}"
        fi
        rmdir "$MOUNT_DIRECTORY_CURRENT" 2> /dev/null
    else
        echo -e "${ANSI_YELLOW}Mount point for ${TMPUSB_DEVICE_PARTITION} not found.${ANSI_RESET}" >&2
    fi
fi


# Change label

if [[ "$NEW_LABEL" != "" ]]; then
    MOUNT_DIRECTORY_CURRENT=`mount | grep "^${TMPUSB_DEVICE_PARTITION}" | cut -d' ' -f3`
    if [[ "$MOUNT_DIRECTORY_CURRENT" != "" ]]; then
        echo "$MOUNT_DIRECTORY_CURRENT"
        echo -e "${ANSI_RED}Cannot write label to currently mounted device ${TMPUSB_DEVICE_PARTITION}!${ANSI_RESET}" >&2
        exit 1
    fi

    if [[ $VERBOSE -ge 2 ]]; then echo -e "${ANSI_BLUE}Writing $NEW_LABEL to $TMPUSB_DEVICE${ANSI_RESET}"; fi

    TEMP_SECTOR_FILE=`mktemp /tmp/$SCRIPT_NAME.XXXXXXXX`
    dd if=/dev/$TMPUSB_DEVICE bs=512 skip=3 count=1 of=$TEMP_SECTOR_FILE 2> /dev/null
    if [[ $VERBOSE -ge 5 ]]; then
        echo -e "${ANSI_BLUE}  Sector content before:"
        cat $TEMP_SECTOR_FILE | hexdump -Cv | head -n 4 | sed -e 's/^/  /'
        echo -ne "${ANSI_RESET}"
    fi

    echo -n "           " | dd of=$TEMP_SECTOR_FILE count=11 conv=notrunc 2> /dev/null
    echo -n "$NEW_LABEL" | dd of=$TEMP_SECTOR_FILE count=${#NEW_LABEL} conv=notrunc 2> /dev/null
    if [[ $VERBOSE -ge 5 ]]; then
        echo -e "${ANSI_BLUE}  Sector content after:"
        cat $TEMP_SECTOR_FILE | hexdump -Cv | head -n 4 | sed -e 's/^/  /'
        echo -ne "${ANSI_RESET}"
    fi

    dd if=$TEMP_SECTOR_FILE bs=512 seek=3 count=1 of=/dev/$TMPUSB_DEVICE 2> /dev/null
    if [[ $? -gt 0 ]]; then
        echo -e "${ANSI_RED}Cannot write label to /dev/${TMPUSB_DEVICE}!${ANSI_RESET}" >&2
        exit 1
    fi
fi


# Mount

if [[ $MOUNT -gt 0 ]]; then
    if [[ $VERBOSE -ge 2 ]]; then echo -e "${ANSI_BLUE}Mounting device ${TMPUSB_DEVICE_PARTITION} into $MOUNT_DIRECTORY${ANSI_RESET}"; fi
    rmdir $MOUNT_DIRECTORY 2> /dev/null
    if [ -d "$MOUNT_DIRECTORY" ]; then
        echo -e "${ANSI_RED}Directory $MOUNT_DIRECTORY already present and not empty!${ANSI_RESET}" >&2
        exit 1
    fi
    mkdir $MOUNT_DIRECTORY
    if command -v mount_msdosfs &> /dev/null; then  # BSD
        mount_msdosfs ${TMPUSB_DEVICE_PARTITION} $MOUNT_DIRECTORY
    else
        mount -t vfat -o rw  ${TMPUSB_DEVICE_PARTITION} $MOUNT_DIRECTORY
    fi
fi


# Report

for DEVICE in $TMPUSB_DEVICES; do
    if [[ "$DEVICE" == "$TMPUSB_DEVICE" ]] || [[ $VERBOSE -ge 1 ]]; then
        LABEL=`dd if=/dev/$DEVICE bs=512 skip=3 count=1 2> /dev/null | hexdump -n11 -e '11/1 "%c"' | tr -d '[[:space:]]'`

        if [[ -e "/dev/${DEVICE}s1" ]]; then  # BSD
            MOUNTED_AT=`mount | grep "^/dev/${DEVICE}s1" | cut -d' ' -f3`
        elif [[ -e "/dev/${DEVICE}1" ]]; then  # Linux
            MOUNTED_AT=`mount | grep "^/dev/${DEVICE}1" | cut -d' ' -f3`
        else
            MOUNTED_AT=""  # cannot figure it out
        fi

        if [[ "$DEVICE" == "$TMPUSB_DEVICE" ]]; then
            printf "${ANSI_CYAN}%s ${ANSI_WHITE}%-11s${ANSI_RESET}" $DEVICE $LABEL
        else
            printf "%s %-11s" $DEVICE $LABEL
        fi
        if [[ "$MOUNTED_AT" != "" ]]; then
            if [[ "$DEVICE" == "$TMPUSB_DEVICE" ]]; then
                echo -n " ${ANSI_TEAL}$MOUNTED_AT${ANSI_RESET}"
            else
                echo -n " $MOUNTED_AT"
            fi
        fi
        echo

        if [[ $VERBOSE -ge 5 ]]; then
            echo -e "${ANSI_BLUE}  Sector content:"
            dd if=/dev/$DEVICE bs=512 skip=3 count=1 2> /dev/null | hexdump -Cv | head -n 4 | sed -e 's/^/  /'
            echo -ne "${ANSI_RESET}"
        fi
    fi
done
