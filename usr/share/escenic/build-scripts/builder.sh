#! /usr/bin/env bash
################################################################################
#
# Script for managing "the builder"
#
################################################################################

# Common variables
ece_scripts_home=/usr/share/escenic/ece-scripts
log=~/builder.log
pid_file=~/builder.pid
root_dir=~/

# Commands
add_user=0
add_artifact=0
add_artifact_list=0

# Command variables
list_path=
artifact_path=
user_name=
user_svn_path=
user_svn_username=
user_maven_username=
user_svn_password="CHANGE_ME"
user_maven_password="CHANGE_ME"

##
function init
{
  init_failed=0
  error_message=""
  if [ ! -d $ece_scripts_home ]; then
    init_failed=1
    error_message="The directory for ece-scripts $ece_scripts_home does not exist, exiting!"
  elif [ ! -e $ece_scripts_home/common-bashing.sh ]; then
    init_failed=1
    error_message="The script $ece_scripts_home/common-bashing.sh does not exist, exiting!"
  elif [ ! -e $ece_scripts_home/common-io.sh ]; then
    init_failed=1
    error_message="The script $ece_scripts_home/common-io.sh does not exist, exiting!"
  fi
  if [ $init_failed -eq 0 ]; then
    source $ece_scripts_home/common-bashing.sh
    source $ece_scripts_home/common-io.sh
  else
    echo "$error_message"
    exit 1
  fi
}

##
function set_pid 
{
  if [ -e $pid_file ]; then
    print_and_log "Instance of $(basename $0) already running!"
    exit 1
  else
    echo $BASHPID > $pid_file
  fi
}

##
function verify_root_privilege
{
  if [ "$(id -u)" != "0" ]; then
    print_and_log "This script must be run as root"
    remove_pid_and_exit_in_error
  fi
}

##
function enforce_variable
{
  if [ ! -n "$(eval echo $`echo $1`)" ]; then
    print_and_log "$2"
    remove_pid_and_exit_in_error
  fi
}

function ensure_no_user_conflict
{
  if [ ! -z "$(getent passwd $user_name)" ]; then
    print_and_log "User $user_name already exist!"
    remove_pid_and_exit_in_error
  fi
  if [ -d /home/$user_name ]; then
    print_and_log "User $user_name does not exist, but has a home folder!"
    remove_pid_and_exit_in_error
  fi
  if [ -d /var/www/$user_name ]; then
    print_and_log "User $user_name does not exist, but has a web root under /var/www/$user_name !"
    remove_pid_and_exit_in_error
  fi
}

##
function common_post_action {
  run rm $pid_file
}

##
function get_user_options
{
  while getopts ":a:l:u:c:s:m:p:" opt; do
    case $opt in
      a)
        print_and_log "Adding artifact ${OPTARG}..."
	add_artifact=1
        artifact_path=${OPTARG}
        ;;
      l)
        print_and_log "Adding list of artifacts ${OPTARG}..."
        add_artifact_list=1
        list_path=${OPTARG}
        ;;
      u)
        print_and_log "Adding user ${OPTARG}..."
        add_user=1          
        user_name=${OPTARG}
	ensure_no_user_conflict
        ;;
      c)
        print_and_log "Using svn path: ${OPTARG}."
        user_svn_path=${OPTARG}
        ;;
      s)
        print_and_log "Using svn username: ${OPTARG}!"
        user_svn_username=${OPTARG}
        ;;
      m)
        print_and_log "Using maven username: ${OPTARG}!"
        user_maven_username=${OPTARG}
        ;;
      p)
        print_and_log "Using password file: ${OPTARG}!"
        user_password_file=${OPTARG}
        if [ ! -e $user_password_file ]; then
          print_and_log "Provided password file does not exist, exiting!" >&2
          remove_pid_and_exit_in_error
        fi
        ;;
      \?)
        print_and_log "Invalid option: -$OPTARG" >&2
        remove_pid_and_exit_in_error
        ;;
      :)
        print_and_log "Option -$OPTARG requires an argument." >&2
        remove_pid_and_exit_in_error
        ;;
    esac
  done

}

##
function execute
{
  if [ $add_user -eq 1 ]; then
    verify_add_user
    add_user
  elif [ $add_artifact -eq 1 ]; then
    verify_add_artifact
    add_artifact
  elif [ $add_artifact_list -eq 1 ]; then
    verify_add_artifact_list
    add_artifact_list
  else
    print_and_log "No valid action chosen, exiting!" >&2
    remove_pid_and_exit_in_error
  fi
}

##
function verify_add_user 
{
  enforce_variable user_name "You need to provide your username using the -u flag."
  ensure_no_user_conflict
  enforce_variable user_svn_path "You need to provide your svn path using the -c flag."
  enforce_variable user_svn_username "You need to provide your svn username using the -s flag."
  enforce_variable user_maven_username "You need to provide your maven username using the -m flag."
  if [ -e "$user_password_file" ]; then
    source $user_password_file
    enforce_variable svn_password "The variable svn_password needs to be present in $user_password_file."
    enforce_variable maven_password "The variable maven_password needs to be present in $user_password_file."
    user_svn_password=$svn_password
    user_maven_password=$maven_password
  fi
}

##
function add_user
{
  run useradd -m -s /bin/bash $user_name
  run ln -s /usr/share/escenic/build-scripts/build.sh /home/$user_name/build.sh
  echo "customer=$user_name
svn_base=$user_svn_path
svn_user=$user_svn_username
svn_password=$user_svn_password
ece_scripts_home=/usr/share/escenic/ece-scripts" > /home/$user_name/build.conf
  run chown $user_name:$user_name /home/$user_name/build.conf
  run rsync -av /home/vosa/skel/ /home/$user_name
  run sed -i "s/maven.username/$user_maven_username/" /home/$user_name/.m2/settings.xml
  run sed -i "s/maven.password/$user_maven_password/" /home/$user_name/.m2/settings.xml
  run chown -R $user_name:$user_name /home/$user_name
  if [ ! -d /var/www/$user_name ]; then
    make_dir /var/www/$user_name
    run chown www-data:www-data /var/www/$user_name  
  else
    print_and_log "Failed to add web root /var/www/$user_name !"
    remove_pid_and_exit_in_error
  fi
  if [ ! -h /var/www/$user_name/releases ]; then
    run ln -s /home/$user_name/releases /var/www/$user_name/releases
  else
    print_and_log "Failed to add symlink for /var/www/$user_name/releases !"
    remove_pid_and_exit_in_error
  fi
}

##
function verify_add_artifact
{
  enforce_variable artifact_path "You need to provide a valid artifact URL using the -a flag."
}

##
function add_artifact 
{
  engine_found=0
  plugin_found=0
  plugin_pattern=""
  if [ -e "$root_dir/downloads" ]; then
    run rm -rf $root_dir/downloads
    make_dir $root_dir/downloads
    make_dir $root_dir/downloads/unpack
  fi
  if [[ "$artifact_path" == *\/engine-* ]]; then
    engine_found=1
    print ""
  fi
  for f in $escenic_plugin_indentifiers; do
    if [[ "$artifact_path" == *$f* ]]; then
      plugin_found=1
      plugin_pattern=$f
    fi
  done  
  if [ $engine_found -eq 1 ] && [ $plugin_found -eq 1 ]; then
    print_and_log "The requested resource $artifact_path has been identified as both an engine and a plugin. Exiting!" >&2
    remove_pid_and_exit_in_error
  elif [ $engine_found -eq 1 ]; then
    run wget --http-user=$technet_user --http-password=$technet_password $artifact_path -O $root_dir/downloads/unpack/resource.zip
    run cd $root_dir/downloads/unpack
    run unzip $root_dir/downloads/unpack/resource.zip
    for f in $(ls -d $root_dir/downloads/unpack/*);
      do
        filename=$(basename "$f")
        echo "$filename" | grep '[0-9]' | grep -q 'engine'
        if [ $? = 0 ]; then
          echo "Directory contains numbers and \"engine\" so it is most likely valid!"
          if [ ! -d "$root_dir/engine/$filename" ]; then
            run mv $f $root_dir/engine/.
          else
            print_and_log "$root_dir/engine/$filename already exists and will be ignored!"
          fi 
        fi
    done
  elif [ $plugin_found -eq 1 ]; then
    run wget --http-user=$technet_user --http-password=$technet_password $artifact_path -O $root_dir/downloads/unpack/resource.zip
    run cd $root_dir/downloads/unpack
    run unzip $root_dir/downloads/unpack/resource.zip
    run rm -f $root_dir/downloads/unpack/resource.zip
    for f in $(ls -d $root_dir/downloads/unpack/*);
      do
        filename=$(basename "$f")
        echo "$filename" | grep '[0-9]' | grep -q "$plugin_pattern"
        if [ $? = 0 ]; then
          echo "Directory contains numbers and \"$plugin_pattern\" so it is most likely valid!"
          if [ ! -d "$root_dir/plugins/$filename" ]; then
            run mv $f $root_dir/plugins/.
          else
            print_and_log "$root_dir/plugins/$filename already exists and will be ignored!"
          fi
        else
          test=`echo $artifact_path | sed "s/.*-\(.*\)\.[a-zA-Z0-9]\{3\}$/\1/"`     
          echo "$plugin_pattern-$test"
          print_and_log "Resource $artifact_path identified as a $plugin_pattern plugin, but failed the naming convention test after being unpacked, trying to recover..."
          if [ ! -d $root_dir/plugins/$plugin_pattern-$test ]; then
            run mv $f $root_dir/plugins/$plugin_pattern-$test
          fi
        fi
    done
  else
    print_and_log "No valid resource identified using $artifact_path, exiting!"
  fi
}

##
function verify_add_artifact_list
{
  enforce_variable list_path "You need to provide a valid path to your artifact list file using the -l flag."
  if [ ! -e $list_path ]; then
    print_and_log "The file $list_path does not exist!, exiting!" >&2
    remove_pid_and_exit_in_error
  fi
}

##
function add_artifact_list
{
  for f in $(cat $list_path);
  do
    add_artifact $f
  done
}

#####################################################
# Run commands
#####################################################
init
set_pid
verify_root_privilege
print_and_log "Starting process @ $(date)"
print_and_log "Additional output can be found in $log_file"
get_user_options $@
execute
common_post_action
print_and_log "Done! @ $(date)"
