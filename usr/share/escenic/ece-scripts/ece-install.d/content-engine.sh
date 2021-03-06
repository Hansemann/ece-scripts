# ece-install module Content Engine specific code.

function get_deploy_white_list() {
  
  local deploy_white_list=""
  local presentation_deploy_white_list="escenic-admin $(get_publication_short_name_list)"
  local editor_deploy_white_list="escenic-admin escenic studio indexer-webservice webservice"
  local search_deploy_white_list="solr indexer-webapp"
  
  # user's deploy white list, if present, takes precedence.
  if [ $fai_enabled -eq 1 ]; then
    if [ $install_profile_number -eq $PROFILE_PRESENTATION_SERVER ]; then
      deploy_white_list=${fai_presentation_deploy_white_list-$presentation_deploy_white_list}
    elif [ $install_profile_number -eq $PROFILE_EDITORIAL_SERVER ]; then
      deploy_white_list=${fai_editor_deploy_white_list-$editor_deploy_white_list}
    elif [ $install_profile_number -eq $PROFILE_SEARCH_SERVER ]; then
      deploy_white_list=${fai_search_deploy_white_list-$search_deploy_white_list}
    else
      deploy_white_list=${fai_publication_deploy_white_list-""}
    fi
  fi

  echo ${deploy_white_list}
}

function get_publication_short_name_list() {
  local short_name_list=""
  
  local publication_def_dir=${escenic_root_dir}/assemblytool/publications

  if [ ! -d $publication_def_dir ]; then
    echo ${short_name_list}
    return
  fi

  if [ $(ls ${publication_def_dir} | grep .properties$ | wc -l) -eq 0 ]; then
    echo ${short_name_list}
    return
  fi

  for el in $(find ${publication_def_dir} -maxdepth 1 -name "*.properties"); do
    local short_name=$(basename $el .properties)
    short_name_list="${short_name_list} ${short_name}"
  done

  echo ${short_name_list}
}

## $1=<default instance name>
function install_ece_instance() {
  install_ece_third_party_packages
  
  ask_for_instance_name $1
  set_up_engine_directories
  set_up_ece_scripts

  set_archive_files_depending_on_profile
  
  # most likely, the user is _not_ installing from archives (EAR +
  # configuration bundle), hence the false test goes first.
  if [ $(is_installing_from_ear) -eq 0 ]; then
    download_escenic_components
    check_for_required_downloads
    set_up_engine_and_plugins

    if [ $install_profile_number -ne $PROFILE_ANALYSIS_SERVER ]; then
      set_up_assembly_tool
    fi
  else
    verify_that_files_exist_and_are_readable \
      $ece_instance_ear_file \
      $ece_instance_conf_archive
  fi

  set_up_app_server
  set_up_proper_logging_configuration

  if [ $install_profile_number -ne $PROFILE_ANALYSIS_SERVER ]; then
    set_up_basic_nursery_configuration
    set_up_instance_specific_nursery_configuration
  fi
  
  # We set a WAR white list for all profiles except all in one
  if [ $install_profile_number -ne $PROFILE_ALL_IN_ONE -a \
    $install_profile_number -ne $PROFILE_ANALYSIS_SERVER ]; then
    local file=$escenic_conf_dir/ece-${instance_name}.conf
    print_and_log "Creating deployment white list in $file ..."
    set_conf_file_value \
      deploy_webapp_white_list \
      $(get_deploy_white_list) \
      $file
  fi

  if [ $install_profile_number -ne $PROFILE_ANALYSIS_SERVER -a \
    $install_profile_number -ne $PROFILE_SEARCH_SERVER ]; then
    install_memory_cache
    assemble_deploy_and_restart_type
  fi
  
  update_type_instances_to_start_up
  set_conf_file_value ece_unix_user $ece_user /etc/default/ece
  set_conf_file_value ece_unix_group $ece_group /etc/default/ece

  stop_and_clear_instance_if_requested
  leave_content_engine_trails

  admin_uri=http://$HOSTNAME:${appserver_port}/escenic-admin/
  add_next_step "New ECE instance $instance_name installed."
  add_next_step "Admin interface: $admin_uri"
  add_next_step "View installed versions with:" \
    " ece -i $instance_name versions"
  add_next_step "Type 'ece help' to see all the options of this script"
  add_next_step "Read its guide: /usr/share/doc/escenic/ece-guide.txt"
  add_next_step "/etc/default/ece lists all instances started at boot time"
}

function set_up_engine_and_plugins() {
  if [ $ece_software_setup_completed -eq 1 ]; then
    return
  fi
  
  print_and_log "Setting up the Escenic Content Engine & its plugins ..."
  make_dir $escenic_root_dir
  run cd $escenic_root_dir/

  for el in $technet_download_list; do
    if [ $(basename $el | \
      grep -E "^engine-[0-9]|^engine-trunk-SNAPSHOT|^engine-dist" | \
      wc -l) -gt 0 ]; then
      engine_dir=$(get_base_dir_from_bundle $download_dir/$(basename $el))
      engine_file=$(basename $el)
    fi
  done
  
  if [ -n "$engine_dir" -a ! -d "${engine_dir}" ]; then
    run unzip -q -u -o $download_dir/${engine_file}
    if [ -h engine ]; then
      run rm engine
    fi
    
    run ln -s ${engine_dir} engine
  else
    debug "${engine_dir} is already there, skipping to next step."
  fi

  # we now extract all the plugins. We extract them in $escenic_root_dir
  # as we want to re-use them between minor updates of ECE.
  run cd $escenic_root_dir/
  for el in $technet_download_list $wf_download_list; do
    local file=$(basename $el)
    if [[ "$el" == engine-* ]]; then
      continue
    fi
    run unzip -q -u -o $download_dir/$file
  done

  ece_software_setup_completed=1
}

function set_up_assembly_tool() {
  log "Setting up the Assembly Tool ..."
  
  make_dir $escenic_root_dir/assemblytool/
  cd $escenic_root_dir/assemblytool/
  
  if [ -e $download_dir/assemblytool*zip ]; then
    run unzip -q -u -o $download_dir/assemblytool*zip
  fi

  # adding an instance layer to the Nursery configuration
  run cp -r $escenic_root_dir/engine/siteconfig/bootstrap-skeleton \
    $escenic_root_dir/assemblytool/conf
  run cd $escenic_root_dir/assemblytool/conf/
  run cp -r layers/host layers/environment
  run cp -r layers/host layers/instance
  run cp -r layers/host layers/vosa
  run cp -r layers/host layers/server
  
  cat > layers/environment/Files.properties <<EOF
\$class=neo.nursery.FileSystemDepot
fileSystemRoot = $escenic_conf_dir/engine/environment/\${com.escenic.environment "unknown"}/
EOF
  cat > layers/instance/Files.properties <<EOF
\$class=neo.nursery.FileSystemDepot
fileSystemRoot = $escenic_conf_dir/engine/instance/\${com.escenic.instance "default"}/
EOF
  cat > layers/vosa/Files.properties <<EOF
\$class=neo.nursery.FileSystemDepot
fileSystemRoot = $escenic_conf_dir/engine/vosa/
EOF
  cat > layers/server/Files.properties <<EOF
\$class=neo.nursery.FileSystemDepot
fileSystemRoot = $escenic_conf_dir/engine/server/\${escenic.server "default"}/
EOF

  cat > Nursery.properties <<EOF
# Configuration layers set up by $(basename $0) @ $(date)

\$class=neo.nursery.Bootstrapper

# ECE :: default layer
layer.01 = /layers/default/Layer

# ECE :: plugins layer
layer.02 = /layers/addon/Layer

# VOSA :: common VOSA/SaaS layer
layer.03 = /layers/vosa/Layer

# Customer :: common layer
layer.04 = /layers/common/Layer

# Customer :: family/group layer (e.g. presentation, editorial)
layer.05 = /layers/family/Layer

# Customer :: environment layer (e.g. testing, staging, production)
layer.06 = /layers/environment/Layer

# Customer :: host specific layer 
layer.07 = /layers/host/Layer

# Customer :: instance specific layer
layer.08 = /layers/instance/Layer

# Customer :: "escenic.server" specific layer, this layer is a
# combination of the host and the instance.
layer.09 = /layers/server/Layer
EOF

  # fixing the path to the Nursery configuration according to
  # escenic_conf_dir which may have been overridden by the user.
  for el in $(find $escenic_root_dir/assemblytool/conf -name Files.properties)
  do
    sed -i "s#/etc/escenic#${escenic_conf_dir}#g" $el
  done
  
  # set up which plugins to use
  run cd $escenic_root_dir/assemblytool/
  make_dir plugins
  run cd plugins
  find ../../ -maxdepth 1 -type d | \
    grep -v assemblytool | \
    while read directory; do
    if [ $directory = "../../" -o \
      $(echo $directory | grep widget-framework | wc -l) -gt 0 ]; then
      continue
    fi
    
    # nuisance to get the community engine and analysis engine, but
    # not the engine
    if [ $(echo $directory | \
      grep engine | \
      grep -v community | \
      grep -v analysis | \
      wc -l) -gt 0 ]; then
      continue
    fi

    make_ln $directory
  done

  run cd $escenic_root_dir/assemblytool/
  run ant -q initialize
  sed -i "s~#\ engine.root\ =\ \.~engine.root=${escenic_root_dir}/engine~g" \
    assemble.properties \
    1>>$log 2>>$log
  exit_on_error "sed on assemble.properties"
  
  sed -i "s~\#\# plugins\ =\ /path/to/plugins~plugins=${escenic_root_dir}/assemblytool/plugins~g" \
    assemble.properties \
    1>>$log 2>>$log
  exit_on_error "sed on assemble.properties"

  make_dir $escenic_root_dir/assemblytool/publications

  # set up user publication definitions
  if [ -n "${fai_publication_war_uri_list}" ]; then
    run cd $escenic_root_dir/assemblytool/publications
    
    wget_auth=$wget_builder_auth
    for el in ${fai_publication_war_uri_list}; do
      local download_file=$(
        download_uri_target_to_dir \
          $el \
          $escenic_root_dir/assemblytool/publications
      )
      
      if [ ! -e $(basename $el) ]; then
        print_and_log "Failed to get user publication $el."
        print_and_log "I will skip it and continue to the next one."
        continue
      fi

      local short_name=$(basename $el .war)
      cat > ${short_name}.properties <<EOF
name: ${short_name}
source-war: ${short_name}.war
context-root: ${short_name}
EOF
    done
  fi
}

function set_up_basic_nursery_configuration() {
  print_and_log "Setting up basic Nursery configuration ..."

  # we always copy the default plugin configuration (even if there is
  # an archive)
  for el in $escenic_root_dir/assemblytool/plugins/*; do
    if [ ! -d $el/misc/siteconfig/ ]; then
      continue
    fi
    run cp -r $el/misc/siteconfig/* $common_nursery_dir/
  done

  # Then we see if we're using configuration archives, if yes, use the
  # JAAS and Nursery configuraiton from here.
  if [ $(is_using_conf_archive) -eq 1 ]; then
    print_and_log "Using the supplied Nursery & JAAS configuration from" 
    print_and_log "bundle: $ece_instance_conf_archive"

    # the conf archive typically resides on the build server, hence we
    # set its authentication credentials here.
    wget_auth=$wget_builder_auth
    
    local a_tmp_dir=$(mktemp -d)
    local file=$(
      download_uri_target_to_dir \
        $ece_instance_conf_archive \
        $a_tmp_dir
    )
    run cd $a_tmp_dir
    extract_archive $file
    
    if [ -d ${a_tmp_dir}/engine/security ]; then
      run cp -r $a_tmp_dir/engine/security/ $common_nursery_dir/
    else
      print "Archive $ece_instance_conf_archive doesn't have JAAS config,"
      print "I'll use standard JAAS (engine/security) instead."
      run cp -r $escenic_root_dir/engine/security/ $common_nursery_dir/
    fi
    
    run cp -r engine/siteconfig/config-skeleton/* $common_nursery_dir/
  else
    print_and_log "I'm using Nursery & JAAS configuration (skeleton) " \
      "from $escenic_root_dir/engine"
    run cp -r $escenic_root_dir/engine/siteconfig/config-skeleton/* \
      $common_nursery_dir/
    run cp -r $escenic_root_dir/engine/security/ $common_nursery_dir/
  fi

  if [ -n "${a_tmp_dir}" ]; then
    run rm -rf ${a_tmp_dir}
  fi
  
  public_host_name=$HOSTNAME:${appserver_port}
  if [ $fai_enabled -eq 1 ]; then
    if [ -n "$fai_public_host_name" ]; then
      public_host_name=$fai_public_host_name
    fi
  else
    print "What is the public address of your website?"
    print "Press ENTER to use the default ($public_host_name)"
    echo -n "Your choice [$public_host_name]> "
    read user_host_name
  fi

  if [ -n "$user_host_name" ]; then
    public_host_name=$user_host_name
  fi
  
  cat > $common_nursery_dir/ServerConfig.properties <<EOF
databaseProductName=MySQL
filePublicationRoot=$escenic_data_dir/engine/
webPublicationRoot=http://${public_host_name}/
EOF
  cat > $common_nursery_dir/neo/io/managers/ContentManager.properties <<EOF
readConnector=/connector/ReadConnector
updateConnector=/connector/UpdateConnector
EOF

  file=$common_nursery_dir/com/escenic/community/CommunityEngine.properties
  if [ -w ${file} ]; then
    sed -i 's/jdbc\/ecome/jdbc\/ECE_UPDATE_DS/g' $file
    exit_on_error "sed on $file"
  elif [ ! -e ${file} ]; then
    print_and_log "I Could not find an ECOME configuration file,"
    print_and_log "I assume you have not installed Community Engine."
  else
    print_and_log "Could not write to ${file},"
    print_and_log "Community Engine might not work because of this. "
    remove_pid_and_exit_in_error
  fi

  file=$common_nursery_dir/com/escenic/webstart/StudioConfig.properties
  cat >> $file <<EOF
# Currently (2012-08-15), ECS insists on JRE = 1.6.
jreRequirement=1.6

# We set this to get around a missing feature in Varnish, see:
# https://www.varnish-cache.org/trac/wiki/Future_Feature#Chunkedencodingclientrequests
# For Escenic-ites, see: VF-3480
property.com.escenic.client.chunked=false

# This font have been tested and works with (at least): English,
# Norwegian & Tamil. The font comes with (at least) MS Office and OS X
# 10.5 and up.
property.com.escenic.studio.font.macosx=Arial Unicode MS
property.com.escenic.studio.font.linux=Arial Unicode MS
property.com.escenic.studio.font.windows7=Arial Unicode MS
property.com.escenic.studio.font.windowsxp=Arial Unicode MS
property.com.escenic.studio.font.windowsvista=Arial Unicode MS
EOF

  set_up_publication_nursery_conf
  set_up_search_client_nursery_conf
}

## Set publication specific configuration, set here and not in
## set_up_instance_specific_nursery_configuration as this
## configuration will be the same on two instaces running on the same
## host.
function set_up_publication_nursery_conf() {
  if [ -n "$fai_publication_domain_mapping_list" ]; then
    local publication_name=""
    local publication_domain=""
    local publication_aliases=""

    for el in $fai_publication_domain_mapping_list; do
      local old_ifs=$IFS
      IFS='#'
      read publication_name publication_domain publication_aliases <<< "$el"
      IFS=$old_ifs
      
      local file=$escenic_conf_dir/engine/environment/${fai_publication_environment-production}/neo/publications/Pub-${publication_name}.properties
      
      print_and_log "Creating Nursery component" \
        $(basename $file .properties) \
        "for publication $publication_name"
      make_dir $(dirname $file)
      cat > $file <<EOF
# Created by $(basename $0) @ $(date)
\$class=neo.xredsys.config.SimplePublicationSupport
url=http://${publication_domain}/
EOF
    done
  fi
}

function set_up_instance_specific_nursery_configuration() {
  print_and_log "Setting up instance specific Nursery configuration ..."
  
  for el in $escenic_conf_dir/engine/instance/*; do
    i=$(( i + 1 ))
    if [ $(basename $el) = $instance_name ]; then
      rmi_port="8${i}23"
      run echo "port=$rmi_port" > $el/RMI.properties
    fi
  done

  nursery_context=neo/io/managers/HubConnectionManager.properties
  file=$escenic_conf_dir/engine/instance/$instance_name/$nursery_context
  make_dir $(dirname $file)
  
  # we don't touch it if the file already exists.
  if [ ! -e $file ]; then
    run echo "hostname=$HOSTNAME" >> $file
  fi
}

function set_up_proper_logging_configuration() {
  print_and_log "Setting up proper log4j & Java logging configuration ..."
  
  cat > $common_nursery_dir/trace.properties <<EOF
log4j.rootLogger=ERROR, ECELOG
log4j.appender.ECELOG=org.apache.log4j.DailyRollingFileAppender
log4j.appender.ECELOG.File=$escenic_log_dir/\${escenic.server}-messages
log4j.appender.ECELOG.layout=org.apache.log4j.PatternLayout
log4j.appender.ECELOG.layout.ConversionPattern=%d %5p [%t] %x (%c) %m%n
EOF
  cd $tomcat_base/lib/
  make_ln $common_nursery_dir/trace.properties
  run ln -sf trace.properties log4j.properies

  # since the solr webapp otherwise will pollute our logs, we ask
  # Tomcat specifically to make it log to dedicated logger.
  if [ $install_profile_number -eq $PROFILE_SEARCH_SERVER -o \
    $install_profile_number -eq $PROFILE_ALL_IN_ONE ]; then
    cat > $tomcat_base/conf/logging.properties <<EOF
handlers = 1catalina.org.apache.juli.FileHandler, 2localhost.org.apache.juli.FileHandler, java.util.logging.ConsoleHandler, 6localhost.org.apache.juli.FileHandler

.handlers = 1catalina.org.apache.juli.FileHandler

1catalina.org.apache.juli.FileHandler.level = FINE
1catalina.org.apache.juli.FileHandler.directory = \$\{catalina.base\}/logs
1catalina.org.apache.juli.FileHandler.prefix = catalina.

2localhost.org.apache.juli.FileHandler.level = FINE
2localhost.org.apache.juli.FileHandler.directory = \$\{catalina.base\}/logs
2localhost.org.apache.juli.FileHandler.prefix = localhost.

java.util.logging.ConsoleHandler.level = FINE
java.util.logging.ConsoleHandler.formatter = java.util.logging.SimpleFormatter

6localhost.org.apache.juli.FileHandler.level = FINE
6localhost.org.apache.juli.FileHandler.directory = $escenic_log_dir
6localhost.org.apache.juli.FileHandler.prefix = solr.

org.apache.solr.level=WARNING
org.apache.solr.handlers=6localhost.org.apache.juli.FileHandler

org.apache.catalina.core.ContainerBase.[Catalina].[localhost].level = INFO
org.apache.catalina.core.ContainerBase.[Catalina].[localhost].handlers = 2localhost.org.apache.juli.FileHandler
EOF
  else
    run cp $tomcat_home/conf/logging.properties $tomcat_base/conf
  fi
}

# Installs third party packages needed by the ECE (i.e. Java related).
# Also see install_common_os_packages for packages common to all
# servers in the architecture.
function install_ece_third_party_packages
{
  run_hook install_ece_third_party_packages.preinst
  print_and_log "Installing 3rd party packages needed by $type instances"
  
  if [ $on_debian_or_derivative -eq 1 ]; then
    if [ $on_ubuntu -eq 1 ]; then
      # Sun Java was removed in Ubuntu in 11.10 and later also from
      # LTS 10.04, hence Hardy is the last one with these package now
      # (2012-02-20 11:22)
      local version_needs_local_java_deb=1004
      local version=$(lsb_release -s -r | sed "s#\.##g")
      
      add_apt_source \
        "deb http://archive.canonical.com/ $(lsb_release -s -c) partner"
    elif [ $on_debian -eq 1 ]; then
      code_name=$(lsb_release -s -c)
      has_non_free=$(grep $(lsb_release -s -c) \
        /etc/apt/sources.list | \
        egrep -v "^#|deb-src" | \
        grep -v security | \
        grep non-free | \
        wc -l)
      if [ $has_non_free -eq 0 ]; then
        add_apt_source "deb http://ftp.${mirror_country_suffix}.debian.org/debian/ $(lsb_release -s -c) contrib non-free"
      fi

      # Sun Java will be removed in the next Debian stable,
      # wheezy (either 6.1 or 7.0 not announced yet, current in
      # squeeze/6.0, hence setting 6.1 here).
      local version_needs_local_java_deb=610
      local version=$(lsb_release -s -r | sed "s#\.##g")
    fi

    # Debian testing has started to report just testing instead of a
    # relase number. Assessed 2012-07-05 10:34
    if [[ $version == "testing" ]]; then
      create_java_deb_packages_and_repo
    elif [ $version -ge $version_needs_local_java_deb -a \
      $(has_sun_java_installed) -eq 0 ]; then
      create_java_deb_packages_and_repo
    fi
    
    echo "sun-java6-jdk shared/accepted-sun-dlj-v1-1 boolean true" | \
      debconf-set-selections

    # Here, we install sun-java6-jdk first so that ant doesn't pull
    # down OpenJDK.
    #
    # This if guard is in palce to not attempt to install the package
    # if Sun Java already is installed (typically, manually
    # installed).
    local packages="sun-java6-jdk"
    if [ $(has_sun_java_installed) -eq 0 ]; then
      install_packages_if_missing $packages
    fi

    packages="
      ant
      ant-contrib
      ant-optional
      libapr1
      libtcnative-1
      libmysql-java
      memcached
      xml-twig-tools
      wget
    "
  elif [ $on_redhat_or_derivative -eq 1 ]; then
    packages="
      ant
      ant-contrib
      ant-nodeps
      apr
      memcached
      mysql-connector-java
      wget
    "

    # TODO no tomcat APR wrappers in official repositories
    install_sun_java_on_redhat
  fi
  
  install_packages_if_missing $packages
  
  for el in ant java jar; do
    assert_pre_requisite $el
  done
}

ece_instance_ear_file=""
ece_instance_conf_archive=""

function set_archive_files_depending_on_profile()
{
  if [ $install_profile_number -eq $PROFILE_PRESENTATION_SERVER ]; then
    ece_instance_ear_file=$fai_presentation_ear
    ece_instance_conf_archive=$fai_presentation_conf_archive
  elif [ $install_profile_number -eq $PROFILE_EDITORIAL_SERVER ]; then
    ece_instance_ear_file=$fai_editor_ear
    ece_instance_conf_archive=$fai_editor_conf_archive
  elif [ $install_profile_number -eq $PROFILE_SEARCH_SERVER ]; then
    ece_instance_ear_file=$fai_search_ear
    ece_instance_conf_archive=$fai_search_conf_archive
  elif [ $install_profile_number -eq $PROFILE_ALL_IN_ONE ]; then
    ece_instance_ear_file=$fai_all_ear
    ece_instance_conf_archive=$fai_all_conf_archive
  else
    # All other profiles don't have EAR support.
    ece_instance_ear_file=""
    ece_instance_conf_archive=""
  fi
}

# Returns 1 if we're installing the ECE instances from a provided EAR
# file
function is_installing_from_ear()
{
  log install_profile_number=$install_profile_number
  log ece_instance_ear_file=$ece_instance_ear_file

  if [[ -z "$ece_instance_ear_file" || \
    $fai_enabled -eq 0 ]]; then
    echo 0
    return
  fi

  echo 1
}

# Returns 1 if we're using a tarball with the Nursery & JAAS configuration.
function is_using_conf_archive(){
  log install_profile_number=$install_profile_number
  log ece_instance_conf_archive=$ece_instance_conf_archive

  if [[ -z "$ece_instance_conf_archive" || \
    $fai_enabled -eq 0 ]]; then
    echo 0
    return
  fi

  echo 1
}

function assemble_deploy_and_restart_type()
{
  set_correct_permissions

  # need to run clean here since we might be running multiple profiles
  # in the same ece-install process.
  ece_command="ece -i $instance_name -t $type clean assemble deploy restart"
  if [ $(is_installing_from_ear) -eq 1 ]; then
    ece_command="ece -i $instance_name \
      -t $type \
      deploy --uri $ece_instance_ear_file \
      restart"
    print_and_log "Deploying the $ece_instance_ear_file on "
    print_and_log "instance $instance_name and restarting it ..."
  else
    print_and_log "Assembling, deploying & starting $instance_name ..."
  fi
  
  su - $ece_user -c "$ece_command" 1>>$log 2>>$log
  exit_on_error "su - $ece_user -c \"$ece_command\""
}

function set_up_engine_directories() {
  for el in $engine_dir_list; do
    make_dir $el
  done
}

function leave_content_engine_trails() {
  if [ ${fai_editor_install-0} -eq 1 ]; then
    leave_trail "trail_editor_port=${fai_editor_port-8080}"
    leave_trail "trail_editor_shutdown=${fai_editor_shutdown-8005}"
  fi
  if [ ${fai_presentation_install-0} -eq 1 ]; then
    leave_trail "trail_presentation_port=${fai_presentation_port-8080}"
    leave_trail "trail_presentation_shutdown=${fai_presentation_shutdown-8005}"
  fi
  if [ ${fai_analysis_install-0} -eq 1 ]; then
    leave_trail "trail_analysis_port=${fai_analysis_port-8080}"
    leave_trail "trail_analysis_shutdown=${fai_analysis_shutdown-8005}"
  fi
  if [ ${fai_all_install-0} -eq 1 ]; then
    leave_trail "trail_all_port=8080"
    leave_trail "trail_all_shutdown=8005"
  fi
  
  leave_trail "trail_public_host_name=${public_host_name}"
}

## stop the ECE or EAE being installed and clear its logs, if so
function stop_and_clear_instance_if_requested() {
  local go_ahead=0

  if [ $install_profile_number -eq $PROFILE_ANALYSIS_SERVER ]; then
    go_ahead=${fai_analysis_stop_and_clear-0}
  elif [ $install_profile_number -eq $PROFILE_EDITORIAL_SERVER ]; then
    go_ahead=${fai_editor_stop_and_clear-0}
  elif [ $install_profile_number -eq $PROFILE_PRESENTATION_SERVER ]; then
    go_ahead=${fai_presentation_stop_and_clear-0}
  elif [ $install_profile_number -eq $PROFILE_ALL_IN_ONE ]; then
    go_ahead=${fai_all_stop_and_clear-0}
  fi

  if [ $go_ahead -eq 1 ]; then
    print_and_log "Stopping and clearing ${instance_name}'s work & log files:"
    local ece_command="ece -i ${instance_name} -t ${type} clean stop"
    run su - ${ece_user} -c "$ece_command"
    local dir_list="
      ${escenic_log_dir}
      ${escenic_cache_dir}
      ${escenic_crash_dir}
      ${tomcat_base}/logs
    "
    for el in $dir_list; do
      if [ ! -d "$el" ]; then
        continue
      fi
      log "Removing all files in $el ..."
      run rm -rf $el/*
    done

  fi
}

## called for presentation & editorial profiles
function set_up_search_client_nursery_conf() {
  local dir=$common_nursery_dir/com/escenic/framework/search/solr
  make_dir $dir
  echo "solrServerURI=http://${search_host}:${search_port}/solr" \
    >>  $dir/SolrSearchEngine.properties
  
  dir=$common_nursery_dir/com/escenic/webservice/search
  make_dir $dir
  echo "solrURI=http://${search_host}:${search_port}/solr/select" \
    >> $dir/DelegatingSearchEngine.properties

  dir=$common_nursery_dir/com/escenic/lucy
  make_dir $dir
  echo "solrURI=http://${search_host}:${search_port}/solr" \
    >> $dir/LucySearchEngine.properties

  dir=$common_nursery_dir/com/escenic/forum/search/lucy
  make_dir $dir
  echo "solrURI=http://${search_host}:${search_port}/solr" \
    >> $dir/SearchEngine.properties
}  

