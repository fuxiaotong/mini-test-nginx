package My::Test::Util;

use strict;
use warnings;

our $VERSION = '0.25';

use base 'Exporter';

use POSIX qw( SIGQUIT SIGKILL SIGTERM SIGHUP );
use File::Spec ();
use HTTP::Response;
use Cwd qw( cwd );
use List::Util qw( shuffle );
use Time::HiRes qw( sleep );
use File::Path qw(make_path);
use File::Find qw(find);
use File::Temp qw( tempfile :POSIX );
use Scalar::Util qw( looks_like_number );
use IO::Socket::INET;
use IO::Socket::UNIX;
use Test::LongString;
use Data::Dumper;
use Carp qw( croak );

our $FilterHttpConfig;
our @CleanupHandlers;
our @BlockPreprocessors;
our $RepeatEach = 1;

our $Timeout = $ENV{TEST_NGINX_TIMEOUT} || 3;
our $NginxBinary            = $ENV{TEST_NGINX_BINARY} || 'nginx';
our $Workers                = 1;
our $WorkerConnections      = 64;
our $LogLevel               = $ENV{TEST_NGINX_LOG_LEVEL} || 'debug';
our $MasterProcessEnabled   = $ENV{TEST_NGINX_MASTER_PROCESS} || 'off';
our $DaemonEnabled          = 'on';
our $ServerPort             = $ENV{TEST_NGINX_SERVER_PORT} || $ENV{TEST_NGINX_PORT} || 80;
our $ServerPortForClient    = $ENV{TEST_NGINX_CLIENT_PORT} || $ENV{TEST_NGINX_PORT} || 80;
our $NoRootLocation         = 0;
our $TestNginxSleep         = $ENV{TEST_NGINX_SLEEP} || 0.015;
our $BuildSlaveName         = $ENV{TEST_NGINX_BUILDSLAVE};
our $ForceRestartOnTest     = (defined $ENV{TEST_NGINX_FORCE_RESTART_ON_TEST})
                               ? $ENV{TEST_NGINX_FORCE_RESTART_ON_TEST} : 1;

our $CheckAccumErrLog = $ENV{TEST_NGINX_CHECK_ACCUM_ERR_LOG};

our $ServerAddr = '127.0.0.1';
our $ServerName = 'localhost';

our $ErrLogFilePos;
our $ChildPid;
our $UdpServerPid;
our $TcpServerPid;
our @EnvToNginx;
our $RunTestHelper;
our $CheckErrorLog;

our @EXPORT = qw(
env_to_nginx
    is_str
    check_accum_error_log
    is_running
    $NoLongString
    no_long_string
    $ServerAddr
    server_addr
    $ServerName
    server_name
    parse_time
    $UseStap
    verbose
    sleep_time
    stap_out_fh
    stap_out_fname
    bail_out
    add_cleanup_handler
    error_log_data
    setup_server_root
    write_config_file
    get_canon_version
    get_nginx_version
    trim
    show_all_chars
    parse_headers
    run_tests
    get_pid_from_pidfile
    $ServerPortForClient
    $ServerPort
    $NginxVersion
    $PidFile
    $ServRoot
    $ConfFile
    $RunTestHelper
    $CheckErrorLog
    $FilterHttpConfig
    $NoNginxManager
    $RepeatEach
    $CheckLeak
    $Benchmark
    $BenchmarkWarmup
    add_block_preprocessor
    timeout
    worker_connections
    workers
    master_on
    master_off
    config_preamble
    repeat_each
    master_process_enabled
    log_level
    no_shuffle
    no_root_location
    html_dir
    server_root
    server_port
    server_port_for_client
    no_nginx_manager
);

our $ServRoot   = $ENV{TEST_NGINX_SERVROOT} || File::Spec->catfile(cwd() || '.', 't/servroot');
our $LogDir     = File::Spec->catfile($ServRoot, 'logs');
our $ErrLogFile = File::Spec->catfile($LogDir, 'error.log');
our $AccLogFile = File::Spec->catfile($LogDir, 'access.log');
our $HtmlDir    = File::Spec->catfile($ServRoot, 'html');
our $ConfDir    = File::Spec->catfile($ServRoot, 'conf');
our $ConfFile   = File::Spec->catfile($ConfDir, 'nginx.conf');
our $PidFile    = File::Spec->catfile($LogDir, 'nginx.pid');


sub bail_out (@);

sub bail_out (@) {
    cleanup();
    Test::More::BAIL_OUT(@_);
}

sub timeout (@) {
    if (@_) {
        $Timeout = shift;
    }
    else {
        $Timeout;
    }
}

sub sleep_time {
    return $TestNginxSleep;
}

sub error_log_data () {
    # this is for logging in the log-phase which is after the server closes the connection:
    sleep $TestNginxSleep * 3;

    open my $in, $ErrLogFile or
        return undef;

    if (!$CheckAccumErrLog && $ErrLogFilePos > 0) {
        seek $in, $ErrLogFilePos, 0;
    }

    my @lines = <$in>;

    if (!$CheckAccumErrLog) {
        $ErrLogFilePos = tell($in);
    }

    close $in;
    return \@lines;
}

sub parse_time ($) {
    my $tm = shift;

    if (defined $tm) {
        if ($tm =~ s/([^_a-zA-Z])ms$/$1/) {
            $tm = $tm / 1000;
        } elsif ($tm =~ s/([^_a-zA-Z])s$/$1/) {
            # do nothing
        } else {
            # do nothing
        }
    }
    return $tm;
}

sub add_block_preprocessor(&) {
    unshift @BlockPreprocessors, shift;
}


sub add_cleanup_handler ($) {
   unshift @CleanupHandlers, shift;
}

sub cleanup () {

    # for my $hdl (@CleanupHandlers) {
    #    $hdl->();
    # }
}

sub get_pid_from_pidfile ($) {
    my ($name) = @_;

    open my $in, $PidFile or
        bail_out("$name - Failed to open the pid file $PidFile for reading: $!");
    my $pid = do { local $/; <$in> };
    chomp $pid;
    #warn "Pid: $pid\n";
    close $in;
    return $pid;
}

sub setup_server_root () {

    if (-d $ServRoot) {     
            # Take special care, so we won't accidentally remove
            # real user data when TEST_NGINX_SERVROOT is mis-used.
            my $rc = system("rm -rf $ConfDir > /dev/null");
            if ($rc != 0) {
                if ($rc == -1) {
                    bail_out "Cannot remove $ConfDir: $rc: $!\n";

                } else {
                    bail_out "Can't remove $ConfDir: $rc";
                }
            }

            system("rm -rf $HtmlDir > /dev/null") == 0 or
                bail_out "Can't remove $HtmlDir";
            system("rm -rf $LogDir > /dev/null") == 0 or
                bail_out "Can't remove $LogDir";
            system("rm -rf $ServRoot/*_temp > /dev/null") == 0 or
                bail_out "Can't remove $ServRoot/*_temp";
            system("rm -rf $ServRoot > /dev/null") == 0 or
                bail_out "Can't remove $ServRoot (not empty?)";
            system("rm ./init_data.lua > /dev/null") == 0 or
                bail_out "Can't remove init_data";
    }

    
    if (!-f $ServRoot) {
       system("touch ./init_data.lua") == 0 or
                bail_out "Can't remove init_data";
    }
    if (!-d $ServRoot) {
        mkdir $ServRoot or
            bail_out "Failed to do mkdir $ServRoot\n";
    }
    if (!-d $LogDir) {
        mkdir $LogDir or
            bail_out "Failed to do mkdir $LogDir\n";
    }
    mkdir $HtmlDir or
        bail_out "Failed to do mkdir $HtmlDir\n";

    my $index_file = "$HtmlDir/index.html";

    open my $out, ">$index_file" or
        bail_out "Can't open $index_file for writing: $!\n";

    print $out '<html><head><title>It works!</title></head><body>It works!</body></html>';

    close $out;

    mkdir $ConfDir or
        bail_out "Failed to do mkdir $ConfDir\n";

}

sub write_config_file ($$) {

    my ($block, $config) = @_;

    my $http_config = $block->http_config;

    my $server_name = 'localhost';

    $http_config = expand_env_in_config($http_config);

    if (!defined $config) {
        $config = '';
    }

    if (!defined $http_config) {
        $http_config = '';
    }

    if ($FilterHttpConfig) {
        $http_config = $FilterHttpConfig->($http_config)
    }

    my $init_env = $block->init_env;

    my $ngx_conf = "$ENV{TEST_NGINX_WORK_DIR}/conf/nginx.conf";
    my $ngx_init_env_conf = "$ConfDir/ngx_init_env.conf";

    system("cp $ENV{TEST_NGINX_WORK_DIR}/conf/* $ConfDir");
    system("cp -r $ENV{TEST_NGINX_WORK_DIR}/lua $ServRoot");

    open my $out_env, ">$ngx_init_env_conf" or
       bail_out "Can't open $ngx_init_env_conf for writing: $!\n";
    print $out_env <<_EOC_;
location /init_env {
    content_by_lua '
$init_env
';
}
_EOC_
close $out_env;
}

sub run_tests() {
    for my $block (Test::Base::blocks()){
        for my $hdl (@BlockPreprocessors) {
            $hdl->($block);
        }
        run_test($block);
        my $pid = get_pid_from_pidfile($block->name);
        # system("kill -9 $pid");
        system("killall nginx");
    }
}

sub expand_env_in_config ($) {
    my $config = shift;

    if (!defined $config) {
        return;
    }

    $config =~ s/\$(TEST_NGINX_[_A-Z0-9]+)/
        if (!defined $ENV{$1}) {
            bail_out "No environment $1 defined.\n";
        }
        $ENV{$1}/eg;

    $config;
}


sub run_test($){
    my $block = shift;
    # print Dumper($block);
    my $dry_run = 0;

    my $name = $block->name;

    my $config = $block->config;
    $config = expand_env_in_config($config);

    local $LogLevel = $LogLevel;
    if ($block->log_level) {
        $LogLevel = $block->log_level;
    }


start_nginx:

    system("redis-cli flushall");
    # system("redis-cli HMSET ...");

    setup_server_root();
    write_config_file($block, $config);

    if (!can_run($NginxBinary)) {
        bail_out("$name - Cannot find the nginx executable in the PATH environment");
        die;
    }

    my $cmd = "$NginxBinary -p $ServRoot/ -c $ConfFile > /dev/null";
    system($cmd);

    sleep $TestNginxSleep;

request:

    my $i = 0;
    $ErrLogFilePos = 0;
    while ($i++ < $RepeatEach) {
        #warn "Use hup: $UseHup, i: $i\n";
        $RunTestHelper->($block, $dry_run, $i - 1);       
    }
    
    if (my $total_errlog = $ENV{TEST_NGINX_ERROR_LOG}) {
        my $errlog = $ErrLogFile;
        if (-s $errlog) {
            open my $out, ">>$total_errlog" or
                bail_out "Failed to append test case title to $total_errlog: $!\n";
            print $out "\n=== $0 $name\n";
            close $out;
            system("cat $errlog >> $total_errlog") == 0 or
                bail_out "Failed to append $errlog to $total_errlog. Abort.\n";
        }
    }
}

END {

    cleanup();

}

# check if we can run some command
sub can_run {
    my ($cmd) = @_;

    #warn "can run: @_\n";
    #my $_cmd = $cmd;
    #return $_cmd if (-x $_cmd or $_cmd = MM->maybe_command($_cmd));

    for my $dir ((split /$Config::Config{path_sep}/, $ENV{PATH}), '.') {
        next if $dir eq '';
        my $abs = File::Spec->catfile($dir, $_[0]);
        return $abs if -f $abs && -x $abs;
    }

    return;
}

1;
