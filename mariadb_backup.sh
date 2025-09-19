#!/bin/bash
# MariaDB Backup Script
# =====================
# This script performs automated backups of MariaDB databases on a replication setup (primary or secondary).
# 
# Key Features:
# - Checks MySQL connectivity and server role (primary via write queries or secondary via replication status).
# - Dumps databases (excluding system schemas) to a dated directory under $DUMP_DEST using mysqldump.
# - Compresses dumps with xz and encrypts them with AES-128-CBC using a password file.
# - Generates Prometheus metrics for backup directories (sizes, averages) and individual dump files (sizes, mtimes).
# - Cleans up files/directories older than $DUMP_EXPIRE_DAYS (default: 7).
# - Uses a lockfile to prevent concurrent runs across servers.
# - Logs all actions to $LOGFILE.
# 
# Usage: Run as root on a MariaDB server. Ensure $AES_PASSWORD_FILE exists and MySQL credentials are configured.
#        Customize paths/variables as needed (e.g., $DUMP_DEST, $DUMP_EXPIRE_DAYS).
# 
# Exit Codes: 0 on success, 1 on failure (with cleanup).
# 
# Dependencies: mysql, mysqldump, xz, openssl, find, du, stat, node_exporter (for metrics).

PROGNAME=$(basename "$0")
DATESTRING=$(date +%Y-%m-%d)
LOGFILE="/var/log/${PROGNAME}.log"
DUMP_EXPIRE_DAYS=7
DUMP_DEST="/path/to/dumps/"
AES_PASSWORD_FILE="/root/.pass.pass"
SHORT_HOSTNAME=$(hostname -s)
LOCKFILE="/path/to/shared/nfs/mount/mariadb_backup.lock"

# Set trap to remove lockfile and exit on interrupt or termination
trap 'cleanup SIGINT' SIGINT
trap 'cleanup SIGTERM' SIGTERM
trap 'cleanup SIGHUP' SIGHUP

loggit () {
  echo -n "$(date +%c) " >> "${LOGFILE}"
  echo "$@" >> "${LOGFILE}"
}
cleanup () {
  local signal=$1
  rm -f "${LOCKFILE}"
  if [ -n "$signal" ]; then
    loggit "Lockfile ${LOCKFILE} removed due to $signal signal."
    exit 1
  else
    loggit "Lockfile ${LOCKFILE} removed."
  fi
}
dyingDeath () {
  echo "dying. check ${LOGFILE} for details."
  loggit "$1"
  cleanup error
  exit 1
}
dyingClean () {
  echo "$1"
  loggit "$1"
  cleanup clean
  exit 0
}
lockfile_check () {
  if [ -f "${LOCKFILE}" ]; then
    dyingClean "Lockfile ${LOCKFILE} exists. Another instance may be running on a different server."
  fi
  echo $$ > "${LOCKFILE}"
  loggit "Lockfile created at ${LOCKFILE} with PID $$"
}
replication_check () {
  # Check if slave is running and replication is caught up
  slave_status=$(mysql -Bse "SHOW SLAVE STATUS\G" 2>/dev/null)
  if [ -z "${slave_status}" ]; then
    loggit "This server is not a replication slave."
    return 1
  fi
  slave_io_running=$(echo "${slave_status}" | grep "Slave_IO_Running:" | awk '{print $2}')
  slave_sql_running=$(echo "${slave_status}" | grep "Slave_SQL_Running:" | awk '{print $2}')
  seconds_behind=$(echo "${slave_status}" | grep "Seconds_Behind_Master:" | awk '{print $2}')
  if [ "${slave_io_running}" = "Yes" ] && [ "${slave_sql_running}" = "Yes" ] && [ "${seconds_behind}" -eq 0 ]; then
    loggit "Replication is running and caught up."
    return 0
  else
    loggit "Replication is not caught up. Slave_IO_Running: ${slave_io_running}, Slave_SQL_Running: ${slave_sql_running}, Seconds_Behind_Master: ${seconds_behind}"
    return 1
  fi
}
primary_check () {
  # Check if replication is good; if so, proceed with backup on secondary
  if replication_check; then
    loggit "Replication is good, proceeding with backup on secondary server."
    return 0
  else
    # Slave is not running or not caught up, check for write queries to determine primary
    write_queries=$(mysql -Bse "SHOW PROCESSLIST" | grep "Query" | grep -Ec "INSERT|UPDATE|DELETE|ALTER|CREATE|DROP")
    if [ "${write_queries}" -gt 0 ]; then
      loggit "Found ${write_queries} write queries, indicating this is the primary server. Proceeding with backup."
      return 0
    else
      dyingClean "No write queries found and replication is not running or caught up. Exiting."
    fi
  fi
}
dump_mysql_local () {
  # dump a local mysql database to $DUMP_DEST
  DUMP_DIRECTORY="${DUMP_DEST}${SHORT_HOSTNAME%-[0-9]*}.${DATESTRING}"
  loggit "Starting local dump to ${DUMP_DIRECTORY}."
  # get a list of the databases
  DBS_TO_BACKUP=$(mysql -Bse "show databases" | grep -Ev '(information_schema|performance_schema)')
  if [ -z "${DBS_TO_BACKUP}" ]; then
    dyingDeath "Failed to retrieve database list. Exiting."
  fi
  # make the backup directory
  mkdir -p "${DUMP_DIRECTORY}"
  for database in ${DBS_TO_BACKUP}; do
    DUMP_FILE_NAME="${DUMP_DIRECTORY}/${database}.sql.xz"
    loggit "Dumping ${database} to ${DUMP_FILE_NAME}."
    if mysqldump --databases "${database}" --single-transaction --skip-lock-tables | xz -1 -c > "${DUMP_FILE_NAME}"; then
      loggit "Dump of ${database} successful."
      loggit "Encrypting ${DUMP_FILE_NAME}."
      if dump_encrypt "${DUMP_FILE_NAME}"; then
        loggit "Encryption of ${DUMP_FILE_NAME} complete."
        rm -f "${DUMP_FILE_NAME}"
      else
        loggit "Encryption of ${DUMP_FILE_NAME} failed."
      fi
    else
      loggit "mysqldump failed for ${database}. Skipping to next database."
    fi
  done
}
dump_encrypt () {
  file_name=$1
  openssl enc -salt -pass file:$AES_PASSWORD_FILE -aes-128-cbc \
    -in "${file_name}" \
    -out "${file_name}.enc" > /dev/null 2>&1
}
monitor_database_backups () {
  textfile_collector_dir="/var/lib/node_exporter"
  output_file="${textfile_collector_dir}/node_file_database_backup.prom.$$"
  mapfile -t last_seven_backup_dir_list < <(
    find "${DUMP_DEST}" \
         -maxdepth 1 \
         -type d \
         -name "${SHORT_HOSTNAME%-[0-9]*}*" \
         -printf '%T@ %p\n' | \
    sort -nr | \
    head -n 7 | \
    cut -d' ' -f2
  )
  most_recent_backup_dir=$(
    find "${DUMP_DEST}" \
         -maxdepth 1 \
         -type d \
         -name "${SHORT_HOSTNAME%-[0-9]*}*" \
         -printf '%T@ %p\n' | \
    sort -nr | \
    head -n 1 | \
    cut -d' ' -f2
  )
  # This could be used in the future.
  # most_recent_backup_dir_size=$(du -s "${most_recent_backup_dir}" | cut -f1)
  mkdir -p "${textfile_collector_dir}"
  loggit "Creating prom file ${output_file}."
  touch ${output_file}
  count=0
  total=0
  for backup_dir in "${last_seven_backup_dir_list[@]}"; do
    if [ -d "$backup_dir" ]; then
      dir_size=$(du -s "${backup_dir}" | cut -f1)
      echo "node_file_database_backup_dir_recent_size_bytes{backup_dir=\"${backup_dir}\"} ${dir_size}" >> ${output_file}
      total=$((total + dir_size))
      ((count++))
    fi
  done
  if (( count > 0 )); then
    average_size=$(( total / count ))
  else
    average_size=0
  fi
  echo "node_file_database_backup_dir_average_size_bytes ${average_size}" >> ${output_file}
  find "${most_recent_backup_dir}" -type f -name '*.xz.enc' | while IFS= read -r backup; do
    file_size=$(stat -c %s "${backup}")
    file_mtime=$(stat -c %Y "${backup}")
    file_name="${backup##*/}"
    database_name="${file_name%%.*}"
    echo "node_file_database_dump_size_bytes{database=\"${database_name}\"} ${file_size}" >> "${output_file}"
    echo "node_file_database_dump_latest_mtime{database=\"${database_name}\"} ${file_mtime}" >> "${output_file}"
  done
  loggit "Moving ${output_file} to ${output_file%.*}."
  mv ${output_file} ${output_file%.*}
}
old_file_cleanup () {
  # Remove all sql files that are older than the expiration.
  FILES_TO_REMOVE=$(find ${DUMP_DEST} -maxdepth 2 -type f -name "*.sql*" -mtime +${DUMP_EXPIRE_DAYS} -not -path "*/keep/*")
  for file_removal in ${FILES_TO_REMOVE}; do
    loggit "Removing ${file_removal}."
    rm -f "${file_removal}"
  done
  DIRS_TO_REMOVE=$(find ${DUMP_DEST} -type d -empty)
  for dir_removal in ${DIRS_TO_REMOVE}; do
    loggit "Removing ${dir_removal}."
    rmdir "${dir_removal}"
  done
  loggit "Purge complete."
}
main () {
  mysqlalivecheck=$(/usr/bin/mysqladmin ping | grep -o alive)
  if [ "${mysqlalivecheck}" == alive ]; then
    # Sleep for a random duration between 1 and 100 milliseconds
    sleep 0.0$((RANDOM % 100 + 1))
    # Check for existing lockfile
    lockfile_check
    # Check if this server is primary or a healthy secondary
    primary_check
    if dump_mysql_local; then
      # if the dump was successful, run the monitoring and cleanup functions
      monitor_database_backups
      old_file_cleanup
    else
      # if the dump failed just run the monitoring and exit. do not cleanup.
      monitor_database_backups
    fi
  else
    # MySQL is not running, exit with a message
    dyingDeath "MySQL is not running. Exiting."
  fi
  # Remove lockfile on successful completion
  cleanup success
}
main