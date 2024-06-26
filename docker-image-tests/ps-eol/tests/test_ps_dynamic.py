#!/usr/bin/env python3
import pytest
import subprocess
import testinfra
import time
from settings import *


container_name = 'ps-docker-test-dynamic'

@pytest.fixture(scope='module')
def host():
    docker_id = subprocess.check_output(
    ['docker', 'run', '--name', container_name, '-e', 'MYSQL_ROOT_PASSWORD='+ps_pwd, '-e', 'INIT_TOKUDB=1', '-e', 'PERCONA_TELEMETRY_URL=https://check-dev.percona.com/v1/telemetry/GenericReport','-d', docker_image]).decode().strip()
    time.sleep(20)
    yield testinfra.get_host("docker://root@" + docker_id)
    # Capture and print Docker logs
    try:
        logs = subprocess.check_output(['docker', 'logs', docker_id]).decode()
        print("\nDocker logs for container '{}':\n".format(container_name))
        print(logs)
    except subprocess.CalledProcessError as e:
        print("Failed to get Docker logs:", e)
    subprocess.check_call(['docker', 'rm', '-f', docker_id])


class TestDynamic:
    def test_tokudb_installed(self, host):
        cmd = host.run('mysql --user=root --password='+ps_pwd+' -S/var/lib/mysql/mysql.sock -s -N -e "select SUPPORT from information_schema.ENGINES where ENGINE = \'TokuDB\';"')
        assert cmd.succeeded
        assert 'YES' in cmd.stdout

    @pytest.mark.parametrize("fname,soname,return_type", ps_functions)
    def test_install_functions(self, host, fname, soname, return_type):
        cmd = host.run('mysql --user=root --password='+ps_pwd+' -S/var/lib/mysql/mysql.sock -s -N -e "CREATE FUNCTION '+fname+' RETURNS '+return_type+' SONAME \''+soname+'\';"')
        assert cmd.succeeded
        cmd = host.run('mysql --user=root --password='+ps_pwd+' -S/var/lib/mysql/mysql.sock -s -N -e "SELECT name FROM mysql.func WHERE dl = \''+soname+'\';"')
        assert cmd.succeeded
        assert fname in cmd.stdout

    @pytest.mark.parametrize("pname,soname", ps_plugins)
    def test_install_plugin(self, host, pname, soname):
        cmd = host.run('mysql --user=root --password='+ps_pwd+' -S/var/lib/mysql/mysql.sock -s -N -e "INSTALL PLUGIN '+pname+' SONAME \''+soname+'\';"')
        assert cmd.succeeded
        cmd = host.run('mysql --user=root --password='+ps_pwd+' -S/var/lib/mysql/mysql.sock -s -N -e "SELECT plugin_status FROM information_schema.plugins WHERE plugin_name = \''+pname+'\';"')
        assert cmd.succeeded
        assert 'ACTIVE' in cmd.stdout

    def test_telemetry_enabled(self, host):
        assert host.file('/usr/local/percona/telemetry_uuid').exists
        assert host.file('/usr/local/percona/telemetry_uuid').contains('PRODUCT_FAMILY_PS')
        assert host.file('/usr/local/percona/telemetry_uuid').contains('instanceId:[0-9a-fA-F]\\{8\\}-[0-9a-fA-F]\\{4\\}-[0-9a-fA-F]\\{4\\}-[0-9a-fA-F]\\{4\\}-[0-9a-fA-F]\\{12\\}$')
