############################################################
# Created by Mohit Joshi                                   #
# Creation date: 20-Jan-2022                               #
############################################################
#!/bin/bash
set +xe

# Same for the same os

BASEDIR1=/home/mysql/percona-xtradb-cluster/install_build/install
BASEDIR2=/home/mysql/percona-xtradb-cluster/install_build/install
BASEDIR3=/home/mysql/percona-xtradb-cluster/install_build/install


FILE_PLUGIN=0
VAULT_PLUGIN=0

PXC_START_TIMEOUT=600

ssh mysql@DB1_PUB """echo "BaseDir1 has been set to: $BASEDIR1";"""

ssh mysql@DB2_PUB """echo "BaseDir2 has been set to: $BASEDIR2";"""

ssh mysql@DB3_PUB """echo "BaseDir3 has been set to: $BASEDIR3";"""

remove_workdir() {

ssh mysql@DB1_PUB """
if [ -d $BASEDIR1/pxc-node ]; then
  echo "Removing existing PXC nodes."
  rm -rf $BASEDIR1/pxc-node
fi
"""
ssh mysql@DB2_PUB """
if [ -d $BASEDIR2/pxc-node ]; then
  echo "Removing existing PXC nodes."
  rm -rf $BASEDIR2/pxc-node
fi
"""
ssh mysql@DB3_PUB """
if [ -d $BASEDIR3/pxc-node ]; then
  echo "Removing existing PXC nodes."
  rm -rf $BASEDIR3/pxc-node
fi
"""
}

kill_server(){
  sudo pkill -9 mysqld
  { sudo pkill -9 $MPID1 && wait $MPID1; } 2>/dev/null
  { sudo pkill -9 $MPID2 && wait $MPID2; } 2>/dev/null
  { sudo pkill -9 $MPID3 && wait $MPID3; } 2>/dev/null
}

create_workdir() {
  
echo "Creating work directories"
WORKDIR1=$BASEDIR1/pxc-node
WORKDIR2=$BASEDIR2/pxc-node
WORKDIR3=$BASEDIR3/pxc-node

ssh mysql@DB1_PUB """
mkdir -p $WORKDIR1
mkdir -p $WORKDIR1/cert
"""

ssh mysql@DB2_PUB """
mkdir -p $WORKDIR2
mkdir -p $WORKDIR2/cert
"""

ssh mysql@DB3_PUB """
mkdir -p $WORKDIR3
mkdir -p $WORKDIR3/cert
"""

echo "Workdir1 has been set to: $WORKDIR1" 
echo "Workdir2 has been set to: $WORKDIR2" 
echo "Workdir3 has been set to: $WORKDIR3" 

SOCKET1=$BASEDIR1/pxc-node/dn1/mysqld.sock
SOCKET2=$BASEDIR2/pxc-node/dn2/mysqld.sock
SOCKET3=$BASEDIR3/pxc-node/dn3/mysqld.sock

ERR_FILE1=$BASEDIR1/pxc-node/node1.err
ERR_FILE2=$BASEDIR2/pxc-node/node2.err
ERR_FILE3=$BASEDIR3/pxc-node/node3.err
}


# Confusion regarding the vault part: I think it should be in any one server (preferably on bootstrap ?)
start_vault_server() {
  #Start vault server for testing
  
  ssh mysql@DB1_PUB """
  echo "Setting up vault server"
  rm -rf $HOME/vault; mkdir $HOME/vault
  rm -rf get_download_link.sh 
  rm -rf vault_test_setup.sh

  wget https://raw.githubusercontent.com/Percona-QA/percona-qa/master/vault_test_setup.sh
  chmod +x vault_test_setup.sh

  wget https://raw.githubusercontent.com/Percona-QA/percona-qa/master/get_download_link.sh
  chmod +x get_download_link.sh

  killall vault > /dev/null 2>&1
  $HOME/vault_test_setup.sh --workdir=$HOME/vault --setup-pxc-mount-points --use-ssl > /dev/null 2>&1

  """
}

sysbench_run() {

ssh mysql@DB1_PUB """  
  echo "printing BASEDIR1 value $BASEDIR1"
  echo "printing SOCKET1 value $SOCKET1"

  echo "...Creating sysbench user"
  $BASEDIR1/bin/mysql -uroot -S$SOCKET1 -e\"CREATE USER 'sysbench'@'localhost' IDENTIFIED BY 'test'\"
  echo "Successful"
  echo "...Granting permissions to sysbench user"
  $BASEDIR1/bin/mysql -uroot -S$SOCKET1 -e\"GRANT ALL ON *.* TO 'sysbench'@'localhost'\"
  echo "Successful"
  echo "...Creating sbtest database"
  $BASEDIR1/bin/mysql -uroot -S$SOCKET1 -e\"DROP DATABASE IF EXISTS sbtest\"
  $BASEDIR1/bin/mysql -uroot -S$SOCKET1 -e\"CREATE DATABASE sbtest ENCRYPTION='Y'\"
  echo "Successful"

  echo "...Preparing sysbench data on Node 1"
  sysbench /usr/share/sysbench/oltp_insert.lua --mysql-db=sbtest --mysql-user=sysbench --mysql-password=test --db-driver=mysql --mysql-socket=$SOCKET1 --threads=5 --tables=50 --table-size=1000 prepare > /dev/null 2>&1
  echo "Data loaded successfully"
  echo "...Running sysbench load on Node 1 for 30 seconds"
  sysbench /usr/share/sysbench/oltp_read_write.lua --mysql-db=sbtest --mysql-user=sysbench --mysql-password=test --db-driver=mysql --mysql-socket=$SOCKET1 --threads=5 --tables=50 --time=30 --report-interval=1 --events=1870000000 --db-ps-mode=disable run > /dev/null 2>&1
  echo "Sysbench run successful"
"""

# Wait for the nodes sync
  sleep 2;
  echo "...Random verification of table counts"
  for X in $(seq 1 10); do
    RAND=$[$RANDOM%50 + 1 ]
  # -N suppresses column names and -s is silent mode
    
    count_1=$(ssh mysql@DB1_PUB """$BASEDIR1/bin/mysql -uroot -S$SOCKET1 -Ns -e\"SELECT count(*) FROM sbtest.sbtest$RAND\" """)
    count_2=$(ssh mysql@DB2_PUB """$BASEDIR2/bin/mysql -uroot -S$SOCKET2 -Ns -e\"SELECT count(*) FROM sbtest.sbtest$RAND\" """)
    count_3=$(ssh mysql@DB3_PUB """$BASEDIR3/bin/mysql -uroot -S$SOCKET3 -Ns -e\"SELECT count(*) FROM sbtest.sbtest$RAND\" """)

  if [ $count_1 -eq $count_2 ]; then
   if [ $count_2 -eq $count_3 ]; then
     echo "Data replicated and matched successfully sbtest$RAND count: $count_1 = $count_2 = $count_3"
   else
     echo "Data mismatch found. sbtest$RAND count: $count_2 : $count_3"
   fi
  else
   echo "Data mismatch found. sbtest$RAND count: $count_1 : $count_2"
   echo "Exiting.."
   exit 1
  fi
done
}

cleanup() {
  component_name=$1
  echo "Deleting global & local manifest files from all 3 nodes"
  for i in $(seq 1 3); do
    if [ $i -eq 1 ]; then
      ssh mysql@DB1_PUB """
        BASEDIR=$BASEDIR1
        WORKDIR=$WORKDIR1
        rm -rf $BASEDIR/bin/mysqld.my || true
        rm -rf $WORKDIR/dn$i/mysqld.my || true
      """
    elif [ $i -eq 2 ]; then
      ssh mysql@DB2_PUB """
        BASEDIR=$BASEDIR2
        WORKDIR=$WORKDIR2
        rm -rf $BASEDIR/bin/mysqld.my || true
        rm -rf $WORKDIR/dn$i/mysqld.my || true
      """
    elif [ $i -eq 3 ]; then
      ssh mysql@DB3_PUB """
        BASEDIR=$BASEDIR3
        WORKDIR=$WORKDIR3
        rm -rf $BASEDIR/bin/mysqld.my || true
        rm -rf $WORKDIR/dn$i/mysqld.my || true
      """
    fi
  done

  echo "Deleting global & local config files from all 3 nodes"
  for i in $(seq 1 3); do
    if [ $i -eq 1 ]; then
      ssh mysql@DB1_PUB """
        BASEDIR=$BASEDIR1
        WORKDIR=$WORKDIR1
        rm -rf $BASEDIR/lib/plugin/component_$component_name.cnf || true
        rm -rf $WORKDIR/dn$i/component_$component_name.cnf || true
      """
    elif [ $i -eq 2 ]; then
      ssh mysql@DB2_PUB """
        BASEDIR=$BASEDIR2
        WORKDIR=$WORKDIR2
        rm -rf $BASEDIR/lib/plugin/component_$component_name.cnf || true
        rm -rf $WORKDIR/dn$i/component_$component_name.cnf || true
      """
    elif [ $i -eq 3 ]; then
      ssh mysql@DB3_PUB """
        BASEDIR=$BASEDIR3
        WORKDIR=$WORKDIR3
        rm -rf $BASEDIR/lib/plugin/component_$component_name.cnf || true
        rm -rf $WORKDIR/dn$i/component_$component_name.cnf || true
      """
    fi
  done
}

create_global_manifest() {
  component_name=$1
  node=$2

  echo "Node$node: Creating global manifest file for component: $component_name"
  if [ "$component_name" == "keyring_file" ]; then
    STRING="file://component_keyring_file"
  elif [ "$component_name" == "keyring_kmip" ]; then
    STRING="file://component_keyring_kmip"
  elif [ "$component_name" == "keyring_kms" ]; then
    STRING="file://component_keyring_kms"
  fi

  if [ $node -eq 1 ]; then
    BASEDIR=$BASEDIR1
    ssh mysql@DB1_PUB """
  set -xe


  cat << EOF >${BASEDIR}/bin/mysqld.my
{ 
\"components\":\"$STRING\"
}
EOF

    """  
  elif [ $node -eq 2 ]; then
    BASEDIR=$BASEDIR2
    ssh mysql@DB2_PUB """
  set -xe


  cat << EOF >${BASEDIR}/bin/mysqld.my
{ 
\"components\":\"$STRING\"
}
EOF


    """
  elif [ $node -eq 3 ]; then
    BASEDIR=$BASEDIR3
    ssh mysql@DB3_PUB """
  set -xe


  cat << EOF >${BASEDIR}/bin/mysqld.my
{ 
\"components\":\"$STRING\"
}
EOF

    """
  fi
}
# Local manifest file is used in pair with Global manifest file
create_local_manifest() {
  component_name=$1
  node=$2

  echo "Node$node: Creating local manifest file for component: $component_name"
  if [ "$component_name" == "keyring_file" ]; then
    STRING="file://component_keyring_file"
  elif [ "$component_name" == "keyring_kmip" ]; then
    STRING="file://component_keyring_kmip"
  elif [ "$component_name" == "keyring_kms" ]; then
    STRING="file://component_keyring_kms"
  fi

  if [ $node -eq 1 ]; then
ssh mysql@DB1_PUB """
  set -xe

    BASEDIR=$BASEDIR1
    WORKDIR=$WORKDIR1
    echo "Node$node: Creating global manifest file for component: $component_name"
    cat << EOF >${BASEDIR}/bin/mysqld.my
{
\"read_local_manifest\":true
}component_keyring_file
EOF

    cat << EOF >${WORKDIR}/dn$node/mysqld.my
{
 \"components\": \"$STRING\"
}
EOF

"""
  elif [ $node -eq 2 ]; then
ssh mysql@DB2_PUB """
  set -xe

    BASEDIR=$BASEDIR2
    WORKDIR=$WORKDIR2
    echo "Node$node: Creating global manifest file for component: $component_name"
    cat << EOF >${BASEDIR}/bin/mysqld.my
{
\"read_local_manifest\":true
}
EOF

    cat << EOF >${WORKDIR}/dn$node/mysqld.my
{
 \"components\": \"$STRING\"
}
EOF

"""
  elif [ $node -eq 3 ]; then
ssh mysql@DB3_PUB """
  set -xe


    BASEDIR=$BASEDIR3
    WORKDIR=$WORKDIR3
    echo "Node$node: Creating global manifest file for component: $component_name"
    cat << EOF >${BASEDIR}/bin/mysqld.my
{
\"read_local_manifest\":true
}
EOF

    cat << EOF >${WORKDIR}/dn$node/mysqld.my
{
 \"components\": \"$STRING\"
}
EOF

"""
  fi

}

# Copy the config

create_global_config() {
  component_name="$1"
  node=$2
  if [ $node -eq 1 ]; then
    BASEDIR=$BASEDIR1
    WORKDIR=$WORKDIR1
ssh mysql@DB1_PUB """

  set -xe

  echo "Node$node: Creating global configuration file for component: $component_name"
  if [ "$component_name" = "keyring_file" ]; then
    cat << EOF >${BASEDIR}/lib/plugin/component_keyring_file.cnf
{
 \"path\": \"${WORKDIR}/dn$node/component_keyring_file\",
 \"read_only\": false
}
EOF
  elif [ "$component_name" = "keyring_kmip" ]; then
    echo "Not Supported"
  elif [ "$component_name" = "keyring_kms" ]; then
    echo "Not Supported"
  fi  
"""

  elif [ $node -eq 2 ]; then
    BASEDIR=$BASEDIR2
    WORKDIR=$WORKDIR2
ssh mysql@DB2_PUB """
  set -xe

  echo "Node$node: Creating global configuration file for component: $component_name"
  if [ "$component_name" = "keyring_file" ]; then
    cat << EOF >${BASEDIR}/lib/plugin/component_keyring_file.cnf
{
 \"path\": \"${WORKDIR}/dn$node/component_keyring_file\",
 \"read_only\": false
}
EOF
  elif [ "$component_name" = "keyring_kmip" ]; then
    echo "Not Supported"
  elif [ "$component_name" = "keyring_kms" ]; then
    echo "Not Supported"
  fi  
"""

  elif [ $node -eq 3 ]; then
    BASEDIR=$BASEDIR3
    WORKDIR=$WORKDIR3
ssh mysql@DB3_PUB """
  set -xe

  echo "Node$node: Creating global configuration file for component: $component_name"
  if [ "$component_name" = "keyring_file" ]; then
    cat << EOF >${BASEDIR}/lib/plugin/component_keyring_file.cnf
{
 \"path\": \"${WORKDIR}/dn$node/component_keyring_file\",
 \"read_only\": false
}
EOF
  elif [ "$component_name" = "keyring_kmip" ]; then
    echo "Not Supported"
  elif [ "$component_name" = "keyring_kms" ]; then
    echo "Not Supported"
  fi  
"""
  fi

}

create_local_config() {
  component_name=$1
  node=$2
  if [ $node -eq 1 ]; then
    BASEDIR=$BASEDIR1
    WORKDIR=$WORKDIR1
ssh mysql@DB1_PUB """
  if [ "$component_name" = "keyring_file" ]; then
    echo "Node$node: Creating global configuration file component_keyring_file.cnf"
    cat << EOF >${BASEDIR}/lib/plugin/component_keyring_file.cnf
{
  \"read_local_config\": true
}
EOF
  echo "Node$node: Creating local configuration file"
  cat << EOF >${WORKDIR}/dn$node/component_keyring_file.cnf
{
 \"path\": \"${WORKDIR}/dn$node/component_keyring_file\",
 \"read_only\": false
}
EOF
  elif [ "$component_name" = "keyring_kmip" ]; then
    echo "Node$node: Creating global configuration file component_keyring_kmip.cnf"
    cat << EOF >${BASEDIR}/lib/plugin/component_keyring_kmip.cnf
{
  \"read_local_config\": true
}
EOF
    echo "Node$node: Creating local configuration file for component: $component_name"
    echo "Not Supported"
  elif [ "$component_name" = "keyring_kms" ]; then
    echo "Node$node: Creating global configuration file component_keyring_kms.cnf"
    cat << EOF >${BASEDIR}/lib/plugin/component_keyring_kms.cnf
{
  \"read_local_config\": true
}
EOF
    echo "Node$node: Creating local configuration file for component: $component_name"
    echo "Not Supported"
  fi
"""
  elif [ $node -eq 2 ]; then
    BASEDIR=$BASEDIR2
    WORKDIR=$WORKDIR2
ssh mysql@DB2_PUB """
  if [ "$component_name" = "keyring_file" ]; then
    echo "Node$node: Creating global configuration file component_keyring_file.cnf"
    cat << EOF >${BASEDIR}/lib/plugin/component_keyring_file.cnf
{
  \"read_local_config\": true
}
EOF
  echo "Node$node: Creating local configuration file"
  cat << EOF >${WORKDIR}/dn$node/component_keyring_file.cnf
{
 \"path\": \"${WORKDIR}/dn$node/component_keyring_file\",
 \"read_only\": false
}
EOF
  elif [ "$component_name" = "keyring_kmip" ]; then
    echo "Node$node: Creating global configuration file component_keyring_kmip.cnf"
    cat << EOF >${BASEDIR}/lib/plugin/component_keyring_kmip.cnf
{
  \"read_local_config\": true
}
EOF
    echo "Node$node: Creating local configuration file for component: $component_name"
    echo "Not Supported"
  elif [ "$component_name" = "keyring_kms" ]; then
    echo "Node$node: Creating global configuration file component_keyring_kms.cnf"
    cat << EOF >${BASEDIR}/lib/plugin/component_keyring_kms.cnf
{
  \"read_local_config\": true
}
EOF
    echo "Node$node: Creating local configuration file for component: $component_name"
    echo "Not Supported"
  fi
"""
  elif [ $node -eq 3 ]; then
    BASEDIR=$BASEDIR3
    WORKDIR=$WORKDIR3
ssh mysql@DB3_PUB """
  if [ "$component_name" = "keyring_file" ]; then
    echo "Node$node: Creating global configuration file component_keyring_file.cnf"
    cat << EOF >${BASEDIR}/lib/plugin/component_keyring_file.cnf
{
  \"read_local_config\": true
}
EOF
  echo "Node$node: Creating local configuration file"
  cat << EOF >${WORKDIR}/dn$node/component_keyring_file.cnf
{
 \"path\": \"${WORKDIR}/dn$node/component_keyring_file\",
 \"read_only\": false
}
EOF
  elif [ "$component_name" = "keyring_kmip" ]; then
    echo "Node$node: Creating global configuration file component_keyring_kmip.cnf"
    cat << EOF >${BASEDIR}/lib/plugin/component_keyring_kmip.cnf
{
  \"read_local_config\": true
}
EOF
    echo "Node$node: Creating local configuration file for component: $component_name"
    echo "Not Supported"
  elif [ "$component_name" = "keyring_kms" ]; then
    echo "Node$node: Creating global configuration file component_keyring_kms.cnf"
    cat << EOF >${BASEDIR}/lib/plugin/component_keyring_kms.cnf
{
  \"read_local_config\": true
}
EOF
    echo "Node$node: Creating local configuration file for component: $component_name"
    echo "Not Supported"
  fi
"""
  fi
}

create_conf() {
node=$1
echo "parameter val is $node"
WORKDIR1="$WORKDIR3"
WORKDIR2="$WORKDIR3"
WORKDIR3="$WORKDIR3"
if [ $node -eq 1 ]; then

echo "Creating n1.cnf"

ssh mysql@DB1_PUB """

set -xe

echo "asdasdasdas"
echo "$WORKDIR1"

ls -la $WORKDIR1/

cat << EOF > $WORKDIR1/n1.cnf
[mysqld]

port = 4000
server-id=1
log-error-verbosity=3
core-file

# file paths
basedir=$BASEDIR1/
datadir=$BASEDIR1/pxc-node/dn1
plugin_dir=$BASEDIR1/lib/plugin/
log-error=$BASEDIR1/pxc-node/node1.err
general_log=1
general_log_file=$BASEDIR1/pxc-node/dn1/general.log
slow_query_log=1
slow_query_log_file=$BASEDIR1/pxc-node/dn1/slow.log
socket=$SOCKET1
character-sets-dir=$BASEDIR1/share/charsets
lc-messages-dir=$BASEDIR1/share/

# pxc variables
log_bin=binlog
binlog_format=ROW
gtid_mode=ON
enforce_gtid_consistency=ON
master_verify_checksum=on
binlog_checksum=CRC32
binlog_encryption=ON
pxc_encrypt_cluster_traffic=ON

# wsrep variables
wsrep_cluster_address='gcomm://DB2_PRIV:6030,DB3_PRIV:6030'
wsrep_provider=$BASEDIR1/lib/libgalera_smm.so
wsrep_sst_receive_address=DB1_PRIV:6020
wsrep_node_incoming_address=DB1_PRIV
wsrep_slave_threads=2
wsrep_cluster_name=my_pxc
wsrep_provider_options = \"gmcast.listen_addr=tcp://DB1_PRIV:6030; base_host=DB1_PRIV; base_port=6030; ist.recv_addr = DB1_PRIV;\"
wsrep_sst_method=xtrabackup-v2
wsrep_node_name=node4000
innodb_autoinc_lock_mode=2

ssl-ca = $WORKDIR1/cert/ca.pem
ssl-cert = $WORKDIR1/cert/server-cert.pem
ssl-key = $WORKDIR1/cert/server-key.pem
[client]
ssl-ca = $WORKDIR1/cert/ca.pem
ssl-cert = $WORKDIR1/cert/client-cert.pem
ssl-key = $WORKDIR1/cert/client-key.pem
[sst]
encrypt = 4
ssl-ca = $WORKDIR1/cert/ca.pem
ssl-cert = $WORKDIR1/cert/server-cert.pem
ssl-key = $WORKDIR1/cert/server-key.pem
EOF

echo "After EOF"
ls -la $WORKDIR1/

if [ $FILE_PLUGIN -eq 1 ]; then
  sed -i '3i early-plugin-load=keyring_file.so' $WORKDIR1/n1.cnf
  sed -i '4i keyring_file_data=keyring' $WORKDIR1/n1.cnf
elif [ $VAULT_PLUGIN -eq 1 ]; then
  sed -i '3i early-plugin-load=keyring_vault.so' $WORKDIR1/n1.cnf
  sed -i '4i loose-keyring_vault_config=/home/mohit.joshi/pxc_scripts/vault/keyring_vault_pxc1.cnf' $WORKDIR1/n1.cnf
fi
"""
fi

if [ $node -eq 2 ]; then

echo "Creating n2.cnf"
ssh mysql@DB2_PUB """
set -xe
cat << EOF > $WORKDIR2/n2.cnf
[mysqld]

port = 5000
server-id=2
log-error-verbosity=3
core-file

# file paths
basedir=$BASEDIR2/
datadir=$BASEDIR2/pxc-node/dn2
plugin_dir=$BASEDIR2/lib/plugin
log-error=$BASEDIR2/pxc-node/node2.err
general_log=1
general_log_file=$BASEDIR2/pxc-node/dn2/general.log
slow_query_log=1
slow_query_log_file=$BASEDIR2/pxc-node/dn2/slow.log
socket=$SOCKET2
character-sets-dir=$BASEDIR2/share/charsets
lc-messages-dir=$BASEDIR2/share/

# pxc variables
binlog_format=ROW
gtid_mode=ON
enforce_gtid_consistency=ON
master_verify_checksum=on
binlog_checksum=CRC32
binlog_encryption=ON
pxc_encrypt_cluster_traffic=ON

# wsrep variables
wsrep_cluster_address='gcomm://DB1_PRIV:6030,DB3_PRIV:6030'
wsrep_provider=$BASEDIR2/lib/libgalera_smm.so
wsrep_sst_receive_address=DB2_PRIV:6020
wsrep_node_incoming_address=DB2_PRIV
wsrep_slave_threads=2
wsrep_cluster_name=my_pxc
wsrep_provider_options = \"gmcast.listen_addr=tcp://DB2_PRIV:6030; base_host=DB2_PRIV; base_port=6030; ist.recv_addr = DB2_PRIV;\"
wsrep_sst_method=xtrabackup-v2
wsrep_node_name=node5000
innodb_autoinc_lock_mode=2

ssl-ca = $WORKDIR2/cert/ca.pem
ssl-cert = $WORKDIR2/cert/server-cert.pem
ssl-key = $WORKDIR2/cert/server-key.pem
[client]
ssl-ca = $WORKDIR2/cert/ca.pem
ssl-cert = $WORKDIR2/cert/client-cert.pem
ssl-key = $WORKDIR2/cert/client-key.pem
[sst]
encrypt = 4
ssl-ca = $WORKDIR2/cert/ca.pem
ssl-cert = $WORKDIR2/cert/server-cert.pem
ssl-key = $WORKDIR2/cert/server-key.pem
EOF

if [ $FILE_PLUGIN -eq 1 ]; then
  sed -i '3i early-plugin-load=keyring_file.so' $WORKDIR2/n2.cnf
  sed -i '4i keyring_file_data=keyring' $WORKDIR2/n2.cnf
elif [ $VAULT_PLUGIN -eq 1 ]; then
  sed -i '3i early-plugin-load=keyring_vault.so' $WORKDIR2/n2.cnf
  sed -i '4i loose-keyring_vault_config=/home/mohit.joshi/pxc_scripts/vault/keyring_vault_pxc2.cnf' $WORKDIR2/n2.cnf
fi
"""
fi

if [ $node -eq 3 ]; then

echo "Creating n3.cnf"
ssh mysql@DB3_PUB """
set -xe

cat << EOF > $WORKDIR3/n3.cnf
[mysqld]

port = 6000
server-id=3
log-error-verbosity=3
core-file

# file paths
basedir=$BASEDIR3/
datadir=$BASEDIR3/pxc-node/dn3
plugin_dir=$BASEDIR3/lib/plugin
log-error=$BASEDIR3/pxc-node/node3.err
general_log=1
general_log_file=$BASEDIR3/pxc-node/dn3/general.log
slow_query_log=1
slow_query_log_file=$BASEDIR3/pxc-node/dn3/slow.log
socket=$SOCKET3
character-sets-dir=$BASEDIR3/share/charsets
lc-messages-dir=$BASEDIR3/share/

# pxc variables
binlog_format=ROW
gtid_mode=ON
enforce_gtid_consistency=ON
master_verify_checksum=on
binlog_checksum=CRC32
binlog_encryption=ON
pxc_encrypt_cluster_traffic=ON

# wsrep variables
wsrep_cluster_address='gcomm://DB1_PRIV:6030,DB2_PRIV:6030'
wsrep_provider=$BASEDIR3/lib/libgalera_smm.so
wsrep_sst_receive_address=DB3_PRIV:6020
wsrep_node_incoming_address=DB3_PRIV
wsrep_slave_threads=2
wsrep_debug=1
wsrep_cluster_name=my_pxc
wsrep_provider_options = \"gmcast.listen_addr=tcp://DB3_PRIV:6030; base_host=DB3_PRIV; base_port=6030; ist.recv_addr = DB3_PRIV;\"
wsrep_sst_method=xtrabackup-v2
wsrep_node_name=node6000
innodb_autoinc_lock_mode=2

ssl-ca = $WORKDIR3/cert/ca.pem
ssl-cert = $WORKDIR3/cert/server-cert.pem
ssl-key = $WORKDIR3/cert/server-key.pem
[client]
ssl-ca = $WORKDIR3/cert/ca.pem
ssl-cert = $WORKDIR3/cert/client-cert.pem
ssl-key = $WORKDIR3/cert/client-key.pem
[sst]
encrypt = 4
ssl-ca = $WORKDIR3/cert/ca.pem
ssl-cert = $WORKDIR3/cert/server-cert.pem
ssl-key = $WORKDIR3/cert/server-key.pem
EOF

if [ $FILE_PLUGIN -eq 1 ]; then
  sed -i '3i early-plugin-load=keyring_file.so' $WORKDIR3/n3.cnf
  sed -i '4i keyring_file_data=keyring' $WORKDIR3/n3.cnf
elif [ $VAULT_PLUGIN -eq 1 ]; then
  sed -i '3i early-plugin-load=keyring_vault.so' $WORKDIR3/n3.cnf
  sed -i '4i loose-keyring_vault_config=/home/mohit.joshi/pxc_scripts/vault/keyring_vault_pxc3.cnf' $WORKDIR3/n3.cnf
fi
"""
fi

}


# how this function will work ?
fetch_err_socket() {
  NR=$1
  if [ $NR -eq 1 ]; then
    BASEDIR=$BASEDIR1
    SOCKET=$SOCKET1
    ERR_FILE=$ERR_FILE1
  elif [ $NR -eq 2 ]; then
    BASEDIR=$BASEDIR2
    SOCKET=$SOCKET2
    ERR_FILE=$ERR_FILE2
  elif [ $NR -eq 3 ]; then
    BASEDIR=$BASEDIR3
    SOCKET=$SOCKET3
    ERR_FILE=$ERR_FILE3
  fi
}
# how this function will work ?
pxc_startup_status(){
  NR=$1

  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if [ $NR -eq 1 ]; then

      SOCKET=$SOCKET1
      ERR_FILE=$ERR_FILE1
      OUTPUT=$(ssh mysql@DB1_PUB """${BASEDIR1}/bin/mysqladmin -uroot -S ${SOCKET} ping | grep 'mysqld is alive'""") > /dev/null 2>&1

    elif [ $NR -eq 2 ]; then

      SOCKET=$SOCKET2
      ERR_FILE=$ERR_FILE2
      OUTPUT=$(ssh mysql@DB2_PUB """${BASEDIR2}/bin/mysqladmin -uroot -S ${SOCKET} ping | grep 'mysqld is alive'""") > /dev/null 2>&1

    elif [ $NR -eq 3 ]; then

      SOCKET=$SOCKET3
      ERR_FILE=$ERR_FILE3
      OUTPUT=$(ssh mysql@DB3_PUB """${BASEDIR3}/bin/mysqladmin -uroot -S ${SOCKET} ping | grep 'mysqld is alive'""") > /dev/null 2>&1
    fi

    echo "OUTPUT Command response: $OUTPUT"

    if [[ ! -z $OUTPUT ]]; then
      echo "Node$NR started successfully. Error log: $ERR_FILE"
      break
    fi
    if [ $X -eq ${PXC_START_TIMEOUT} ]; then
      echo "Node$NR could not start within the time period. Error log: $ERR_FILE"
      exit 1
    fi
  done
}
# how this function will work ?
init_datadir_template() {

  ssh mysql@DB1_PUB """

  set -xe

  rm -rf $BASEDIR1/data.template
  mkdir $BASEDIR1/data.template
  mkdir -p $BASEDIR1/cert
  echo "Creating datadir template db1"
  $BASEDIR1/bin/mysqld --no-defaults --datadir=$BASEDIR1/data.template/dn1 --basedir=$BASEDIR1 --initialize-insecure --log-error=$BASEDIR1/data.template/node1.err
  """

  ssh mysql@DB2_PUB """

  set -xe
  echo "Before"
  rm -rf $BASEDIR2/data.template
  mkdir $BASEDIR2/data.template
  mkdir -p $BASEDIR2/cert
  echo "should be empty"
  echo "Creating datadir template db2"
  $BASEDIR2/bin/mysqld --no-defaults --datadir=$BASEDIR2/data.template/dn2 --basedir=$BASEDIR2 --initialize-insecure --log-error=$BASEDIR2/data.template/node2.err
  """

  ssh mysql@DB3_PUB """

  set -xe
  rm -rf $BASEDIR3/data.template
  mkdir $BASEDIR3/data.template
  mkdir -p $BASEDIR3/cert
  echo "Creating datadir template  db3"
  $BASEDIR3/bin/mysqld --no-defaults --datadir=$BASEDIR3/data.template/dn3 --basedir=$BASEDIR3 --initialize-insecure --log-error=$BASEDIR3/data.template/node3.err
  """

  echo "Data template created successfully"
}

# how this function will work ?
init_datadir() {
  echo "Creating data directories"
  
  ssh mysql@DB1_PUB """

  set -xe

  echo "Data directory creating for dn1 on node 1"

  cp -r $BASEDIR1/data.template/dn1 $WORKDIR1/
  
  echo "Data directory created $WORKDIR1"
  
  cp -r $WORKDIR1/dn1/*.pem $WORKDIR1/cert/

  scp $WORKDIR1/dn1/*.pem mysql@DB2_PRIV:$WORKDIR2/cert/

  scp $WORKDIR1/dn1/*.pem mysql@DB3_PRIV:$WORKDIR3/cert/
  
  """

  ssh mysql@DB2_PUB """
  set -xe
  cp -r $BASEDIR2/data.template/dn2 $WORKDIR2/
  echo "Data directory created for dn2 $WORKDIR2"
  """

  ssh mysql@DB3_PUB """
  set -xe
  cp -r $BASEDIR2/data.template/dn3 $WORKDIR3/
  echo "Data directory created for dn3 $WORKDIR3"
  """
}

start_node1(){
    echo "Starting PXC nodes..."
    fetch_err_socket 1
  ssh mysql@DB1_PUB """
    set -xe

    $BASEDIR1/bin/mysqld --defaults-file=$BASEDIR1/pxc-node/n1.cnf --wsrep_new_cluster > ${ERR_FILE} 2>&1 &
    
  """
    pxc_startup_status 1
}

start_node2() {
    fetch_err_socket 2

  ssh mysql@DB2_PUB """
    set -xe

    $BASEDIR2/bin/mysqld --defaults-file=$BASEDIR2/pxc-node/n2.cnf > ${ERR_FILE} 2>&1 &
  """
    pxc_startup_status 2
    #sleep 100
}

start_node3() {
    fetch_err_socket 3

  ssh mysql@DB3_PUB """
  set -xe

    $BASEDIR3/bin/mysqld --defaults-file=$BASEDIR3/pxc-node/n3.cnf > ${ERR_FILE} 2>&1 &
  """
    pxc_startup_status 3

}

cluster_up_check() {
echo "Checking 3 node PXC Cluster startup..."
for X in $(seq 0 10); do
  
  sleep 1
  CLUSTER_UP=0;
  

    if [ $(ssh mysql@DB1_PUB """${BASEDIR1}/bin/mysql -uroot -S${SOCKET1} -e\"show global status like 'wsrep_cluster_size'\" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" """ | awk '{print$2}') -eq 3 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi

    if [ $(ssh mysql@DB2_PUB """${BASEDIR1}/bin/mysql -uroot -S${SOCKET2} -e\"show global status like 'wsrep_cluster_size'\" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" """ | awk '{print$2}') -eq 3 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi

    if [ $(ssh mysql@DB3_PUB """${BASEDIR1}/bin/mysql -uroot -S${SOCKET3} -e\"show global status like 'wsrep_cluster_size'\" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" """ | awk '{print$2}') -eq 3 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi

    if [ "$(ssh mysql@DB1_PUB """${BASEDIR1}/bin/mysql -uroot -S${SOCKET1} -e\"show global status like 'wsrep_local_state_comment'\" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" """ | awk '{print$2}')" == "Synced" ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi

    if [ "$(ssh mysql@DB2_PUB """${BASEDIR1}/bin/mysql -uroot -S${SOCKET2} -e\"show global status like 'wsrep_local_state_comment'\" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" """ | awk '{print$2}')" == "Synced" ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi

    if [ "$(ssh mysql@DB3_PUB """${BASEDIR1}/bin/mysql -uroot -S${SOCKET3} -e\"show global status like 'wsrep_local_state_comment'\" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" """ | awk '{print$2}')" == "Synced" ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi

  # If count reached 6 (there are 6 checks), then the Cluster is up & running and consistent in it's Cluster topology views (as seen by each node)
  if [ ${CLUSTER_UP} -eq 6 ]; then
    echo "3 Node PXC Cluster started ok. Clients:"
    echo "Node #1: `echo ${BASEDIR1}/bin/mysql | sed 's|/mysqld|/mysql|'` -uroot -S${SOCKET1}"
    echo "Node #2: `echo ${BASEDIR2}/bin/mysql | sed 's|/mysqld|/mysql|'` -uroot -S${SOCKET2}"
    echo "Node #3: `echo ${BASEDIR3}/bin/mysql | sed 's|/mysqld|/mysql|'` -uroot -S${SOCKET3}"
    break
  fi
done
}

###########################################
# Actual testing starts here              #
###########################################
echo "Killing any previous running mysqld"

ssh mysql@DB1_PUB """
pkill -9 mysql
"""

ssh mysql@DB2_PUB """
pkill -9 mysql
"""

ssh mysql@DB3_PUB """
pkill -9 mysql
"""

sleep 2
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_file
cleanup keyring_kmip

echo "###########################################################################"
echo "#Testing Combo 5: component_keyring_file |Global Manifest | Global Config #"
echo "###########################################################################" 
init_datadir_template # Can be removed after wards as inited in combo 1 
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_global_manifest keyring_file 1
create_global_manifest keyring_file 2
create_global_manifest keyring_file 3
create_global_config keyring_file 1
create_global_config keyring_file 2
create_global_config keyring_file 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

start_vault_server
exit 1

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_file

exit 1

#echo "###########################################################################"
#echo "#Testing Combo 1: component_keyring_kms |Global Manifest | Global Config #"
#echo "###########################################################################"
#init_datadir_template
#create_workdir
#create_conf 1
#create_conf 2
#create_conf 3
#init_datadir
#create_global_manifest keyring_kms 1
#create_local_manifest keyring_kms 2
#create_global_manifest keyring_kms 3
#create_global_config keyring_kms 1
#create_global_config keyring_kms 2
#create_global_config keyring_kms 3
#start_node1;MPID1="$!"
#start_node2;MPID2="$!"
#start_node3;MPID3="$!"
#cluster_up_check
#sysbench_run
#
#echo "Killing previous running mysqld"
#kill_server
#remove_workdir
#echo "Cleaning up all previous global and local manifest and config files"
#cleanup keyring_kms
#
#exit 1
#echo "###########################################################################"
#echo "#Testing Combo 2: component_keyring_kms | Global Manifest | Local Config #"
#echo "###########################################################################"
#create_workdir
#create_conf 1
#create_conf 2
#create_conf 3
#init_datadir
#create_global_manifest keyring_kms 1
#create_global_manifest keyring_kms 2
#create_global_manifest keyring_kms 3
#create_local_config keyring_kms 1
#create_local_config keyring_kms 2
#create_local_config keyring_kms 3
#start_node1;MPID1="$!"
#start_node2;MPID2="$!"
#start_node3;MPID3="$!"
#cluster_up_check
#sysbench_run

#echo "Killing previous running mysqld"
#kill_server
#remove_workdir
#echo "Cleaning up all previous global and local manifest and config files"
#cleanup keyring_kms

#echo "###########################################################################"
#echo "#Testing Combo 3: component_keyring_kms | Local Manifest | Global Config #"
#echo "###########################################################################"
#create_workdir
#create_conf 1
#create_conf 2
#create_conf 3
#init_datadir
#create_local_manifest keyring_kms 1
#create_local_manifest keyring_kms 2
#create_local_manifest keyring_kms 3
#create_global_config keyring_kms 1
#create_global_config keyring_kms 2
#create_global_config keyring_kms 3
#start_node1;MPID1="$!"
#start_node2;MPID2="$!"
#start_node3;MPID3="$!"
#cluster_up_check
#sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kms

echo "###########################################################################"
echo "#Testing Combo 4: component_keyring_kms | Local Manifest | Local Config  #"
echo "###########################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_local_manifest keyring_kms 1
create_local_manifest keyring_kms 2
create_local_manifest keyring_kms 3
create_local_config keyring_kms 1
create_local_config keyring_kms 2
create_local_config keyring_kms 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kms

echo "###########################################################################"
echo "#Testing Combo 5: component_keyring_file |Global Manifest | Global Config #"
echo "###########################################################################" 
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_global_manifest keyring_file 1
create_global_manifest keyring_file 2
create_global_manifest keyring_file 3
create_global_config keyring_file 1
create_global_config keyring_file 2
create_global_config keyring_file 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_file

echo "###########################################################################"
echo "#Testing Combo 6: component_keyring_file | Global Manifest | Local Config #"
echo "###########################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_global_manifest keyring_file 1
create_global_manifest keyring_file 2
create_global_manifest keyring_file 3
create_local_config keyring_file 1
create_local_config keyring_file 2
create_local_config keyring_file 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_file

echo "###########################################################################"
echo "#Testing Combo 7: component_keyring_file | Local Manifest | Global Config #"
echo "###########################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_local_manifest keyring_file 1
create_local_manifest keyring_file 2
create_local_manifest keyring_file 3
create_global_config keyring_file 1
create_global_config keyring_file 2
create_global_config keyring_file 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_file

echo "###########################################################################"
echo "#Testing Combo 8: component_keyring_file | Local Manifest | Local Config  #"
echo "###########################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_local_manifest keyring_file 1
create_local_manifest keyring_file 2
create_local_manifest keyring_file 3
create_local_config keyring_file 1
create_local_config keyring_file 2
create_local_config keyring_file 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_file

echo "############################################################################"
echo "#Testing Combo 9: component_keyring_kmip | Global Manifest | Global Config #"
echo "############################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_global_manifest keyring_kmip 1
create_global_manifest keyring_kmip 2
create_global_manifest keyring_kmip 3
create_global_config keyring_kmip 1
create_global_config keyring_kmip 2
create_global_config keyring_kmip 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip

echo "###########################################################################"
echo "#Testing Combo 10: component_keyring_kmip | Global Manifest | Local Config #"
echo "###########################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_global_manifest keyring_kmip 1
create_global_manifest keyring_kmip 2
create_global_manifest keyring_kmip 3
create_local_config keyring_kmip 1
create_local_config keyring_kmip 2
create_local_config keyring_kmip 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip

echo "###########################################################################"
echo "#Testing Combo 11: component_keyring_kmip | Local Manifest | Global Config #"
echo "###########################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_local_manifest keyring_kmip 1
create_local_manifest keyring_kmip 2
create_local_manifest keyring_kmip 3
create_global_config keyring_kmip 1
create_global_config keyring_kmip 2
create_global_config keyring_kmip 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip

echo "###########################################################################"
echo "#Testing Combo 12: component_keyring_kmip | Local Manifest | Local Config  #"
echo "###########################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_local_manifest keyring_kmip 1
create_local_manifest keyring_kmip 2
create_local_manifest keyring_kmip 3
create_local_config keyring_kmip 1
create_local_config keyring_kmip 2
create_local_config keyring_kmip 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing any previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_file
cleanup keyring_kmip

echo "###########################################################################"
echo "# Testing Combo 13: component_keyring_kms                                 #"
echo "# Node 1: Global Manifest | Global Config                                 #"
echo "# Node 2: Local Manifest  | Local Config                                  #"
echo "# Node 3: Global Manifest | Local Config                                  #"
echo "###########################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_global_manifest keyring_kms 1
create_local_manifest keyring_kms 2
create_global_manifest keyring_kms 3
create_global_config keyring_kms 1
create_local_config keyring_kms 2
create_local_config keyring_kms 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kms

echo "############################################################################"
echo "# Testing Combo 14: component_keyring_kms                                  #"
echo "# Node 1: Global Manifest | Local Config                                   #"
echo "# Node 2: Local Manifest  | Global Config                                  #"
echo "# Node 3: Global Manifest | Global Config                                  #"
echo "############################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_global_manifest keyring_kms 1
create_local_manifest keyring_kms 2
create_global_manifest keyring_kms 3
create_local_config keyring_kms 1
create_global_config keyring_kms 2
create_global_config keyring_kms 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kms

echo "###########################################################################"
echo "# Testing Combo 15: component_keyring_kms                                 #"
echo "# Node 1: Local Manifest  | Global Config                                 #"
echo "# Node 2: Global Manifest | Local Config                                  #"
echo "# Node 3: Local Manifest  | Local Config                                  #"
echo "###########################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_local_manifest keyring_kms 1
create_global_manifest keyring_kms 2
create_local_manifest keyring_kms 3
create_global_config keyring_kms 1
create_local_config keyring_kms 2
create_local_config keyring_kms 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kms

echo "###########################################################################"
echo "# Testing Combo 16: component_keyring_kms                                 #"
echo "# Node 1: Local Manifest  | Local Config                                  #"
echo "# Node 2: Global Manifest | Local Config                                  #"
echo "# Node 3: Global Manifest | Global Config                                 #"
echo "###########################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_local_manifest keyring_kms 1
create_global_manifest keyring_kms 2
create_global_manifest keyring_kms 3
create_local_config keyring_kms 1
create_local_config keyring_kms 2
create_global_config keyring_kms 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kms

echo "###########################################################################"
echo "# Testing Combo 17: component_keyring_file                                 #"
echo "# Node 1: Global Manifest | Global Config                                 #"
echo "# Node 2: Local Manifest  | Local Config                                  #"
echo "# Node 3: Global Manifest | Local Config                                  #"
echo "###########################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_global_manifest keyring_file 1
create_local_manifest keyring_file 2
create_global_manifest keyring_file 3
create_global_config keyring_file 1
create_local_config keyring_file 2
create_local_config keyring_file 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_file

echo "############################################################################"
echo "# Testing Combo 18: component_keyring_file                                 #" 
echo "# Node 1: Global Manifest | Local Config                                   #"
echo "# Node 2: Local Manifest  | Global Config                                  #"
echo "# Node 3: Global Manifest | Global Config                                  #"
echo "############################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_global_manifest keyring_file 1
create_local_manifest keyring_file 2
create_global_manifest keyring_file 3
create_local_config keyring_file 1
create_global_config keyring_file 2
create_global_config keyring_file 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_file

echo "###########################################################################"
echo "# Testing Combo 19: component_keyring_file                                #"
echo "# Node 1: Local Manifest  | Global Config                                 #"
echo "# Node 2: Global Manifest | Local Config                                  #"
echo "# Node 3: Local Manifest  | Local Config                                  #"
echo "###########################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_local_manifest keyring_file 1
create_global_manifest keyring_file 2
create_local_manifest keyring_file 3
create_global_config keyring_file 1
create_local_config keyring_file 2
create_local_config keyring_file 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_file

echo "###########################################################################"
echo "# Testing Combo 20: component_keyring_file                                #"
echo "# Node 1: Local Manifest  | Local Config                                  #"
echo "# Node 2: Global Manifest | Local Config                                  #"
echo "# Node 3: Global Manifest | Global Config                                 #"
echo "###########################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_local_manifest keyring_file 1
create_global_manifest keyring_file 2
create_global_manifest keyring_file 3
create_local_config keyring_file 1
create_local_config keyring_file 2
create_global_config keyring_file 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_file

echo "###########################################################################"
echo "# Testing Combo 21: component_keyring_kmip                                #"
echo "# Node 1: Global Manifest | Global Config                                 #"
echo "# Node 2: Local Manifest  | Local Config                                  #"
echo "# Node 3: Global Manifest | Local Config                                  #"
echo "###########################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_global_manifest keyring_kmip 1
create_local_manifest keyring_kmip 2
create_global_manifest keyring_kmip 3
create_global_config keyring_kmip 1
create_local_config keyring_kmip 2
create_local_config keyring_kmip 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip

echo "############################################################################"
echo "# Testing Combo 22: component_keyring_kmip                                 #"
echo "# Node 1: Global Manifest | Local Config                                   #"
echo "# Node 2: Local Manifest  | Global Config                                  #"
echo "# Node 3: Global Manifest | Global Config                                  #"
echo "############################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_global_manifest keyring_kmip 1
create_local_manifest keyring_kmip 2
create_global_manifest keyring_kmip 3
create_local_config keyring_kmip 1
create_global_config keyring_kmip 2
create_global_config keyring_kmip 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip

echo "###########################################################################"
echo "# Testing Combo 23: component_keyring_kmip                                #"
echo "# Node 1: Local Manifest  | Global Config                                 #"
echo "# Node 2: Global Manifest | Local Config                                  #"
echo "# Node 3: Local Manifest  | Local Config                                  #"
echo "###########################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_local_manifest keyring_kmip 1
create_global_manifest keyring_kmip 2
create_local_manifest keyring_kmip 3
create_global_config keyring_kmip 1
create_local_config keyring_kmip 2
create_local_config keyring_kmip 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip

echo "###########################################################################"
echo "# Testing Combo 24: component_keyring_kmip                                #"
echo "# Node 1: Local Manifest  | Local Config                                  #"
echo "# Node 2: Global Manifest | Local Config                                  #"
echo "# Node 3: Global Manifest | Global Config                                 #"
echo "###########################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_local_manifest keyring_kmip 1
create_global_manifest keyring_kmip 2
create_global_manifest keyring_kmip 3
create_local_config keyring_kmip 1
create_local_config keyring_kmip 2
create_global_config keyring_kmip 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip

echo "#####################################################################"
echo "# Testing Combo 25: Cross Component Testing                         #"
echo "# Node 1: component_keyring_kmip | Local Manifest  | Global Config  #"
echo "# Node 2: component_keyring_file | Global Manifest | Local Config   #"
echo "# Node 3: component_keyring_kmip | Local Manifest  | Global Config  #"
echo "####################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_local_manifest keyring_kmip 1
create_global_manifest keyring_file 2
create_local_manifest keyring_kmip 3
create_global_config keyring_kmip 1
create_local_config keyring_file 2
create_global_config keyring_kmip 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip
cleanup keyring_file

echo "#####################################################################"
echo "# Testing Combo 26: Cross Component Testing                         #"
echo "# Node 1: component_keyring_kmip | Local Manifest  | Global Config  #"
echo "# Node 2: component_keyring_kms  | Global Manifest | Local Config   #"
echo "# Node 3: component_keyring_file | Local Manifest  | Global Config  #"
echo "#####################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_local_manifest keyring_kmip 1
create_global_manifest keyring_kms 2
create_local_manifest keyring_file 3
create_global_config keyring_kmip 1
create_local_config keyring_kms 2
create_global_config keyring_file 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip
cleanup keyring_kms
cleanup keyring_file

echo "#####################################################################"
echo "# Testing Combo 27: Cross Component Testing                         #"
echo "# Node 1: component_keyring_kms | Local Manifest  | Global Config   #"
echo "# Node 2: component_keyring_file  | Global Manifest | Local Config  #"
echo "# Node 3: component_keyring_kmip | Local Manifest  | Global Config  #"
echo "#####################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_local_manifest keyring_kms 1
create_global_manifest keyring_file 2
create_local_manifest keyring_kmip 3
create_global_config keyring_kms 1
create_local_config keyring_file 2
create_global_config keyring_kmip 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip
cleanup keyring_kms
cleanup keyring_file


echo "#####################################################################"
echo "# Testing Combo 28: Cross Component Testing                         #"
echo "# Node 1: component_keyring_kms  | Local Manifest  | Global Config  #"
echo "# Node 2: component_keyring_kmip | Global Manifest | Local Config   #"
echo "# Node 3: component_keyring_file | Local Manifest  | Global Config  #"
echo "#####################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_local_manifest keyring_kms 1
create_global_manifest keyring_kmip 2
create_local_manifest keyring_file 3
create_global_config keyring_kms 1
create_local_config keyring_kmip 2
create_global_config keyring_file 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip
cleanup keyring_kms
cleanup keyring_file

echo "#####################################################################"
echo "# Testing Combo 29: Cross Component Testing                         #"
echo "# Node 1: component_keyring_file | Local Manifest  | Global Config  #"
echo "# Node 2: component_keyring_kmip  | Global Manifest | Local Config  #"
echo "# Node 3: component_keyring_kms | Local Manifest  | Global Config   #"
echo "#####################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_local_manifest keyring_file 1
create_global_manifest keyring_kmip 2
create_local_manifest keyring_kms 3
create_global_config keyring_file 1
create_local_config keyring_kmip 2
create_global_config keyring_kms 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip
cleanup keyring_kms
cleanup keyring_file

echo "#####################################################################"
echo "# Testing Combo 30: Cross Component Testing                         #"
echo "# Node 1: component_keyring_file | Local Manifest  | Global Config  #"
echo "# Node 2: component_keyring_kms  | Global Manifest | Local Config   #"
echo "# Node 3: component_keyring_kmip | Local Manifest  | Global Config  #"
echo "#####################################################################"
create_workdir
create_conf 1
create_conf 2
create_conf 3
init_datadir
create_local_manifest keyring_file 1
create_global_manifest keyring_kms 2
create_local_manifest keyring_kmip 3
create_global_config keyring_file 1
create_local_config keyring_kms 2
create_global_config keyring_kmip 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip
cleanup keyring_kms
cleanup keyring_file

echo "#####################################################################"
echo "# Testing Combo 31: Component/Plugin Testing                        #"
echo "# Node 1: component_keyring_kmip | Local Manifest  | Global Config  #"
echo "# Node 2: keyring_file                                              #"
echo "# Node 3: component_keyring_kmip | Local Manifest  | Global Config  #"
echo "#####################################################################"
create_workdir
create_conf 1
FILE_PLUGIN=1
create_conf 2
FILE_PLUGIN=0
create_conf 3
init_datadir
create_local_manifest keyring_kmip 1
create_local_manifest keyring_kmip 3
create_global_config keyring_kmip 1
create_global_config keyring_kmip 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip
cleanup keyring_file

echo "#####################################################################"
echo "# Testing Combo 32: Component/Plugin Testing                        #"
echo "# Node 1: component_keyring_kmip | Local Manifest  | Global Config  #"
echo "# Node 2: keyring_vault                                             #"
echo "# Node 3: component_keyring_kmip | Local Manifest  | Global Config  #"
echo "#####################################################################"
start_vault_server
create_workdir
create_conf 1
VAULT_PLUGIN=1
create_conf 2
VAULT_PLUGIN=0
create_conf 3
init_datadir
create_local_manifest keyring_kmip 1
create_local_manifest keyring_kmip 3
create_global_config keyring_kmip 1
create_global_config keyring_kmip 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip

echo "#####################################################################"
echo "# Testing Combo 33: Component/Plugin Testing                        #"
echo "# Node 1: component_keyring_kmip | Global Manifest  | Local Config  #"
echo "# Node 2: keyring_file                                              #"
echo "# Node 3: component_keyring_file | Local Manifest  | Global Config  #"
echo "#####################################################################"
create_workdir
create_conf 1
FILE_PLUGIN=1
create_conf 2
FILE_PLUGIN=0
create_conf 3
init_datadir
create_global_manifest keyring_kmip 1
create_local_manifest keyring_file 3
create_local_config keyring_kmip 1
create_global_config keyring_file 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip
cleanup keyring_file

echo "#####################################################################"
echo "# Testing Combo 34: Component/Plugin Testing                        #"
echo "# Node 1: component_keyring_kms  | Global Manifest | Local Config   #"
echo "# Node 2: keyring_file                                              #"
echo "# Node 3: component_keyring_file | Local Manifest  | Global Config  #"
echo "#####################################################################"
create_workdir
create_conf 1
FILE_PLUGIN=1
create_conf 2
FILE_PLUGIN=0
create_conf 3
init_datadir
create_global_manifest keyring_kms 1
create_local_manifest keyring_file 3
create_local_config keyring_kms 1
create_global_config keyring_file 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kms
cleanup keyring_file

echo "#####################################################################"
echo "# Testing Combo 35: Component/Plugin Testing                        #"
echo "# Node 1: component_keyring_kms | Global Manifest  | Local Config   #"
echo "# Node 2: keyring_vault                                             #"
echo "# Node 3: component_keyring_kmip | Local Manifest  | Global Config  #"
echo "#####################################################################"
create_workdir
create_conf 1
VAULT_PLUGIN=1
create_conf 2
VAULT_PLUGIN=0
create_conf 3
init_datadir
create_global_manifest keyring_kms 1
create_local_manifest keyring_kmip 3
create_local_config keyring_kms 1
create_global_config keyring_kmip 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kms
cleanup keyring_kmip

echo "#####################################################################"
echo "# Testing Combo 36: Component/Plugin Testing                        #"
echo "# Node 1: keyring_file                                              #"
echo "# Node 2: component_keyring_kmip | Local Manifest  | Local Config   #"
echo "# Node 3: component_keyring_file | Local Manifest  | Global Config  #"
echo "#####################################################################"
create_workdir
FILE_PLUGIN=1
create_conf 1
FILE_PLUGIN=0
create_conf 2
create_conf 3
init_datadir
create_local_manifest keyring_kmip 2
create_local_manifest keyring_file 3
create_local_config keyring_kmip 2
create_global_config keyring_file 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip
cleanup keyring_file

echo "#####################################################################"
echo "# Testing Combo 37: Component/Plugin Testing                        #"
echo "# Node 1: keyring_file                                              #"
echo "# Node 2: component_keyring_file | Local Manifest  | Local Config   #"
echo "# Node 3: component_keyring_kmip | Local Manifest  | Global Config  #"
echo "#####################################################################"
create_workdir
FILE_PLUGIN=1
create_conf 1
FILE_PLUGIN=0
create_conf 2
create_conf 3
init_datadir
create_local_manifest keyring_file 2
create_local_manifest keyring_kmip 3
create_local_config keyring_file 2
create_global_config keyring_kmip 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip
cleanup keyring_file


echo "#####################################################################"
echo "# Testing Combo 38: Component/Plugin Testing                        #"
echo "# Node 1: keyring_file                                              #"
echo "# Node 2: component_keyring_kmip | Local Manifest  | Local Config   #"
echo "# Node 3: keyring_vault                                             #"
echo "#####################################################################"
start_vault_server
create_workdir
FILE_PLUGIN=1
create_conf 1
FILE_PLUGIN=0
create_conf 2
VAULT_PLUGIN=1
create_conf 3
VAULT_PLUGIN=0
init_datadir
create_local_manifest keyring_kmip 2
create_local_config keyring_kmip 2
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip

echo "#####################################################################"
echo "# Testing Combo 39: Component/Plugin Testing                        #"
echo "# Node 1: component_keyring_file | Global Manifest | Local Config   #"
echo "# Node 2: keyring_vault                                             #"
echo "# Node 3: component_keyring_kmip | Local Manifest  | Global Config  #"
echo "#####################################################################"
start_vault_server
create_workdir
create_conf 1
VAULT_PLUGIN=1
create_conf 2
VAULT_PLUGIN=0
create_conf 3
init_datadir
create_global_manifest keyring_file 1
create_local_config keyring_file 1
create_local_manifest keyring_kmip 3
create_global_config keyring_kmip 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip
cleanup keyring_file

echo "#####################################################################"
echo "# Testing Combo 40: Component/Plugin Testing                        #"
echo "# Node 1: component_keyring_file | Global Manifest | Local Config   #"
echo "# Node 2: keyring_file                                              #"
echo "# Node 3: component_keyring_kmip | Local Manifest  | Global Config  #"
echo "#####################################################################"
create_workdir
create_conf 1
FILE_PLUGIN=1
create_conf 2
FILE_PLUGIN=0
create_conf 3
init_datadir
create_global_manifest keyring_file 1
create_local_manifest keyring_kmip 3
create_local_config keyring_file 1
create_global_config keyring_kmip 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip
cleanup keyring_file

echo "#####################################################################"
echo "# Testing Combo 41: Component/Plugin Testing                        #"
echo "# Node 1: keyring_vault                                             #"
echo "# Node 2: component_keyring_file | Global Manifest | Local Config   #"
echo "# Node 3: component_keyring_kmip | Local Manifest  | Global Config  #"
echo "#####################################################################"
start_vault_server
create_workdir
VAULT_PLUGIN=1
create_conf 1
VAULT_PLUGIN=0
create_conf 2
create_conf 3
init_datadir
create_global_manifest keyring_file 2
create_local_manifest keyring_kmip 3
create_local_config keyring_file 2
create_global_config keyring_kmip 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip
cleanup keyring_file


echo "#####################################################################"
echo "# Testing Combo 42: Component/Plugin Testing                        #"
echo "# Node 1: keyring_vault                                             #"
echo "# Node 2: component_keyring_kmip | Local Manifest  | Local Config   #"
echo "# Node 3: component_keyring_kmip | Local Manifest  | Global Config  #"
echo "#####################################################################"
start_vault_server
create_workdir
VAULT_PLUGIN=1
create_conf 1
VAULT_PLUGIN=0
create_conf 2
create_conf 3
init_datadir
create_local_manifest keyring_kmip 2
create_local_manifest keyring_kmip 3
create_local_config keyring_kmip 2
create_global_config keyring_kmip 3
start_node1;MPID1="$!"
start_node2;MPID2="$!"
start_node3;MPID3="$!"
cluster_up_check
sysbench_run

echo "Killing previous running mysqld"
kill_server
remove_workdir
echo "Cleaning up all previous global and local manifest and config files"
cleanup keyring_kmip
