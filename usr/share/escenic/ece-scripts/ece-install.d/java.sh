sun_java_bin_url=http://download.oracle.com/otn-pub/java/jdk/6u31-b04/jdk-6u31-linux-i586.bin
if [[ $(uname -m) == "x86_64" ]]; then
  sun_java_bin_url=http://download.oracle.com/otn-pub/java/jdk/6u31-b04/jdk-6u31-linux-x64.bin
fi
  
function create_java_deb_packages_and_repo() {
  print $(lsb_release -i | cut -d':' -f2) \
    $(lsb_release -r | cut -d':' -f2) \
    "doesn't have official Sun/Oracle Java packages,"
  print "creating packages & local repo for you ..."
  
  local tmp_dir=$(mktemp -d)
  run cd $tmp_dir
  run git clone https://github.com/flexiondotorg/oab-java6.git
  run cd oab-java6
  run bash oab-java.sh
  run rm -rf $tmp_dir
    
  add_next_step "Local APT repository with Sun/Oracle Java packages"
  add_next_step "has been installed at /var/local/oab/deb and added"
  add_next_step "to your APT system with /etc/apt/sources.list.d/oab.list"
}


function install_sun_java_on_redhat() {
  if [[ $(${java_home}/bin/java -version 2>&1 | \
    grep HotSpot | wc -l) -gt 0 ]]; then
    print_and_log "Sun Java is already installed on $HOSTNAME"
    return
  fi
  
  print_and_log "Downloading Sun Java from download.oracle.com ..."
  run cd $download_dir
  run wget $wget_opts $sun_java_bin_url

  # calculating start and stop offset from where to extract the zip
  # from the java data blob. calculation taken from
  # git://github.com/rraptorr/sun-java6.git
  local tmp_jdk=jdk-tmp.zip
  local file_name=$(basename $sun_java_bin_url)
  local binsize=$(wc -c $file_name | awk '{print $1}');
	local zipstart=$(unzip -ql $file_name 2>&1 >/dev/null | \
    sed -n -e 's/.* \([0-9][0-9]*\) extra bytes.*/\1/p');
	tail -c $(expr $binsize - $zipstart) $file_name > $tmp_jdk

  run cd /opt
  run unzip -q -o $download_dir/$tmp_jdk
  local latest_jdk=$(find . -maxdepth 1 -type d -name "jdk*" | sort -r | head -1)
  run rm -f /opt/jdk
  run ln -s $latest_jdk jdk

  # generate jar files from the .pack files
  for el in $(find /opt/jdk/ -name "*.pack"); do
    file_name=$(basename $el .pack)
    local dir=$(dirname $el)
    run /opt/jdk/bin/unpack200 $el $dir/$file_name.jar
  done

  # update RedHat's alternatives system to use Sun Java as its
  # default.
  for el in java javac jar; do
    if [ ! -e /usr/bin/$el ]; then
      ln -s /usr/bin/$el /etc/alternatives/$el
    fi
    # doesn't seem to like running inside the run wrapper
    alternatives --set $el /opt/jdk/bin/$el 1>>$log 2>>$log
  done

  # setting java_home to the newly installed location
  java_home=/opt/jdk
  
  local version=$(java -version 2>&1 | grep version | cut -d'"' -f2)
  print_and_log "Sun Java $version is now installed in /opt/jdk"

  add_next_step "By using Sun Java, you must accept this license: "
  add_next_step "http://www.oracle.com/technetwork/java/javase/terms/license/"
}



