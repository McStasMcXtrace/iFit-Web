#!/usr/bin/perl -w

# requirements:
#   sudo apt-get install apache2 libapache2-mod-perl2 libcgi-pm-perl ifit-phonons libsys-cpu-perl libsys-cpuload-perl libnet-dns-perl libproc-background-perl
# sudo apt install qemu-kvm bridge-utils libqcow2 qemu iptables dnsmasq libproc-processtable-perl
# sudo adduser www-data libvirt
# sudo adduser www-data kvm
# sudo chmod 755 /etc/qemu-ifup

# ensure all fatals go to browser during debugging and set-up
# comment this BEGIN block out on production code for security
BEGIN {
    $|=1;
    use CGI::Carp('fatalsToBrowser');
}

use CGI;              # use CGI.pm
use File::Temp      qw/ tempfile tempdir /;
use Net::Domain     qw(hostname hostfqdn);
use File::Basename  qw(fileparse);
use Sys::CPU;           # libsys-cpu-perl           for CPU::cpu_count
use Sys::CpuLoad;       # libsys-cpuload-perl       for CpuLoad::load
use Proc::Background;   # libproc-background-perl   for Background->new
use Proc::Killfam;      # libproc-processtable-perl for killfam (kill pid and children)

# ==============================================================================
# DECLARE all our variables
# ==============================================================================

# CGI stuff --------------------------------------------------------------------
$CGI::POST_MAX = 1024*5000; # max 5M upload
my $q     = new CGI;    # create new CGI object
my $error = "";

# identification stuff ---------------------------------------------------------
my @cpuload = Sys::CpuLoad::load();
my $cpunb   = Sys::CPU::cpu_count();
my $cpuload0= $cpuload[0];

my $host         = hostname;
my $fqdn         = hostfqdn();
my $remote_host = $q->remote_host();
my $server_name = $q->server_name();
my $datestring  = localtime();

# service stuff ----------------------------------------------------------------
my $service     = "cloud_vm";
my $upload_base = "/var/www/html";   # root of the HTML web server area
my $upload_dir  = "$upload_base/ifit-web-services/upload"; # where to store files. Must exist.
my $upload_short = $upload_dir;
$upload_short =~ s|$upload_base/||;

my $redirect    = "";
my $vm          = "";
my $cmd         = "";
my $res         = "";
my $vm_name     = "";
my $html_handle;
my $html_name   = "";
my $base_name   = "";
my $proc_novnc  = "";
my $proc_qemu   = "";
my ( $name, $path );

# both IP and PORT will be random in 0-254.
my $id          = 0;
my $novnc_port  = 0;
my $novnc_token = "";
my $token_name  = "";
my $token_handle;
my $lock_name   = ""; # filename written to indicate IP:PORT lock
my $lock_handle;
my $qemuvnc_ip  = "";
my $id_ok       = 0;  # flag true when we found a non used IP/PORT
my $output      = "";

# ==============================================================================
# GET and CHECK input parameters
# ==============================================================================

# test if we are working from the local machine 127.0.0.1 == ::1 in IPv6)
if ($remote_host eq "::1") {
  $fqdn = "localhost";
  $host = $fqdn;
  $remote_host = $fqdn;
}
if ($fqdn eq "localhost") {
  $fqdn = inet_ntoa(
        scalar gethostbyname( $host || 'localhost' )
    );
  $host = $fqdn;
  $remote_host = $fqdn;
}
$output .= "<li>[OK] Starting on $datestring</li>\n";
$output .= "<li>[OK] The server name is $server_name.</li>\n";
$output .= "<li>[OK] You are accessing this service from $remote_host.</li>\n";

# test host load
if ($cpuload0 > 1.25*$cpunb) {
  $error .= "CPU load exceeded. Current=$cpuload0. Available=$cpunb. Try again later. ";
} else {
  $output .= "<li>[OK] Server $server_name load $cpuload0 is acceptable.</li>\n";
}

# testing/security
if (not $error) {
  if ($res = $q->cgi_error()){
    if ($res =~ /^413\b/o) {
      $error .= "Maximum data limit exceeded. ";
    }
    else {
      $error .= "An unknown error has occured. "; 
    }
  }
}

# now get values from thre HTML form
if (not $error) {
  $vm       = $q->param('vm');   # 1- VM base name, must match a $vm.ova filename
  if ( !$vm )
  {
    $error .= "There was a problem selecting the Virtual Machine. ";
  } else {
    $output .= "<li>[OK] Selected virtual machine $vm.</li>\n";
  }
}

# check input file name
if (not $error) {
  ( $name, $path ) = fileparse ( $vm );
  $vm = $name;
  $vm =~ tr/ /_/;
  $vm =~ s/[^a-zA-Z0-9_.\-]//g; # safe_filename_characters
  if ( $vm =~ /^([a-zA-Z0-9_.\-]+)$/ ) {
    $vm = $1;
  } else {
    $error .= "Virtual Machine file name contains invalid characters. ";
  }
}

# a test is made to see if the port has already been allocated.
# we search the 1st free port (allow up to 99)
if (not $error) {
  for ($id=1; $id<100; $id++) {
    $novnc_port  = 6079 + $id;
    $lock_name   = "$upload_dir/$service.$novnc_port";
    $qemuvnc_ip  = "127.0.0.$id";
    if (not -e $lock_name) { $id_ok = 1; last; };  # exit loop if the ID is OK
  }
  # check for the existence of the IP:PORT pair.
  if (not $id_ok) { 
    $error .= "Can not assign port for session. Try again later. ";
  } else {
    $output .= "<li>[OK] Assigned $qemuvnc_ip:$novnc_port.</li>\n";
  }
}

# ==============================================================================
# DO the work
# ==============================================================================

# define where our stuff will be (snapshot and HTML file)
# use 'upload' directory to store the temporary VM. 
# Keep it after creation so that the VM can run.
$base_name = tempdir(TEMPLATE => "$service" . "_XXXXX", DIR => $upload_dir, CLEANUP => 1);

# initiate the HTML output
# WE OPEN A TEMPORARY HTML DOCUMENT, WRITE INTO IT, THEN REDIRECT TO IT.
# The HTML document contains some text (our output).
# This way the cgi script can launch all and the web browser display is made independent
# (else only display CGI dynamic content when script ends).
$html_name = $base_name . "/index.html";
( $name, $path ) = fileparse ( $base_name );

if (open($html_handle, '>', $html_name)) {
  # display information in the temporary HTML file

  print $html_handle <<END_HTML;
<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">
<html>
<head>
  <title>$service: $vm [$fqdn]</title>
</head>
<body>
  <img alt="iFit" title="iFit"
    src="http://$server_name/ifit-web-services/images/iFit-logo.png"
    align="right" width="116" height="64">
  <img
    alt="SOLEIL" title="SOLEIL"
    src="http://$server_name/ifit-web-services/images/logo_soleil.png"
    align="right" border="0" height="64">
  <h1>$service: Virtual Machines: $vm</h1>
  <img alt="virtualmachines" title="virtualmachines"
    src="http://$server_name/ifit-web-services/cloud/virtualmachines/images/virtualmachines.png"
    align="right" height="128" width="173">
END_HTML
  close $html_handle;
} else {
  # this indicates 'upload' is probably not there, or incomplete installation
  $error .= "Can not open $html_name (initial open). ";
  error($error);
}

# set temporary VM file (snapshot)
$vm_name = $base_name . "/$service.qcow2";

# CREATE SNAPSHOT FROM BASE VM IN THAT TEMPORARY FILE
if (not $error) {
  if (-e "$upload_dir/$vm.qcow2") {
    $cmd = "qemu-img create -b $upload_dir/$vm.qcow2 -f qcow2 $vm_name";
    $res = `$cmd`;
    $output .= "<li>[OK] Created snapshot from <a href='http://$server_name/ifit-web-services/upload/$vm.qcow2'>$vm.qcow2</a> in <a href='http://$server_name/ifit-web-services/upload/$name/index.html'>$name</a></li>\n";
  } else {
    $error .= "Virtual Machine $vm file does not exist on this server. ";
  }
}

# check for existence of cloned VM
sleep(1); # make sure the VM has been cloned
if (not $error and not -e $vm_name) {
  $error .= "Could not clone Virtual Machine $vm into snapshot. ";
}

# LAUNCH CLONED VM with QXL video driver, KVM, and VNC, 4 cores
if (not $error) {
  # cast a random token key for VNC
  sub rndStr{ join'', @_[ map{ rand @_ } 1 .. shift ] };
  $novnc_token = rndStr 8, 'a'..'z', 'A'..'Z', 0..9;  # 8 random chars in [a-z A-Z digits]

  $cmd = "qemu-system-x86_64 -m 4096 -hda $vm_name -machine pc,accel=kvm -enable-kvm " .
    "-smp 4 -net user -net nic,model=ne2k_pci -cpu host -boot c -vga qxl -vnc $qemuvnc_ip:1";
  
  if ($novnc_token) {
    # must avoid output to STDOUT, so redirect STDOUT to NULL.
    # Any redirection or pipe triggers a 'sh' to launch qemu. 
    # The final 'die' only kills 'sh', not qemu. We use 'killfam' at END for this.
    # $cmd = "echo 'change vnc password\n$novnc_token\n' | " . $cmd . ",password -monitor stdio > /dev/null";
    
    # file created just for the launch, removed immediately. 
    # Any 'pipe' such as "echo 'change vnc password\n$novnc_token\n' | qemu ..." is shown in 'ps'.
    # With a temp file and redirection, the token does not show in the process list (ps).
    $token_name = $base_name . "/token"; 
    open($token_handle, '>', $token_name);
    print $token_handle "change vnc password\n$novnc_token\n";
    close($token_handle);
    # redirect 'token' to STDIN to set the VNC password
    $cmd .= ",password -monitor stdio > /dev/null < $token_name";
  }
  $proc_qemu = Proc::Background->new($cmd);
  if (not $proc_qemu) {
    $error .= "Could not start QEMU/KVM for $vm. ";
  } else {
    $output .= "<li>[OK] Started QEMU/VNC for $vm with VNC on $qemuvnc_ip:1 and token '$novnc_token'</li>\n";
    if (-e $token_name) { unlink($token_name); } # remove any footprint of the token
  }
}

# LAUNCH NOVNC (do not wait for VNC to stop)
if (not $error) {
  $cmd= "$upload_base/ifit-web-services/cloud/virtualmachines/novnc/utils/websockify/run" .
    " --web $upload_base/ifit-web-services/cloud/virtualmachines/novnc/" .
    " --run-once $novnc_port $qemuvnc_ip:5901";

  $proc_novnc = Proc::Background->new($cmd);
  if (not $proc_novnc) {
    $error .= "Could not start noVNC. ";
  } else {
    $output .= "<li>[OK] Started noVNC session $novnc_port to listen to $qemuvnc_ip:5901</li>\n";
  }
}

# ------------------------------------------------------------------------------
# create the HTML output (either OK, or error), and display it.

# display information in the temporary HTML file
if (open($html_handle, '>>', $html_name)) {

  if (not $error) {
    $redirect="http://$fqdn:$novnc_port/vnc.html?host=$fqdn&port=$novnc_port";

    print $html_handle <<END_HTML;
<ul>
$output
<li>[OK] No error, all is fine</li>
<li><b>[OK]</b> Connect with token <b>$novnc_token</b> to your machine at <a href=$redirect target=_blank><b>$redirect</b></a>.</li>
</ul>

<h1><a href=$redirect target=_blank>$redirect</a></h1>
<h1>Use one-shot token '$novnc_token' to connect</h1>
<h3>Please exit properly the virtual machine (lower left corner/Logout/Shutdown)</h3>

<p>
Your machine $service $vm has just started. 
Open the following <a href=$redirect target=_blank>link to display its screen</a> 
(click on the <b>Connect</b> button). 
Remember that the virtual machine is created on request, and destroyed afterwards. You should then export any work done there-in elsewhere (e.g. mounted disk, ssh/sftp, Dropbox, OwnCloud...).
</p>
<hr>
<a href="http://$server_name/ifit-web-services/">iFit Web Services</a> / (c) E. Farhi Synchrotron SOLEIL (2019).
</body>
</html>
END_HTML
    close $html_handle;
    
    # we create a lock file
    if (open($lock_handle, '>', $lock_name)) {;
      print $lock_handle <<END_TEXT;
date: $datestring
service: $service
machine: $vm
pid: $$
ip: $qemuvnc_ip
port: $novnc_port
directory: $base_name
END_TEXT
      close $lock_handle;
    }
    # LOG in /var/log/apache2/error.log
    print STDERR "[$datestring] $service: launched: QEMU $vm VNC=$qemuvnc_ip:5901 redirected to $novnc_port http://$server_name/ifit-web-services/upload/$name/index.html -> $redirect token=$novnc_token\n";
    
  } else {
    print STDERR "[$datestring] $service: ERROR: $error\n";
    print $html_handle <<END_HTML;
    <ul>
      $output
      <li><b>[ERROR]</b> $error</li>
    </ul>
  </body>
  </html>
END_HTML
    close $html_handle;
  }
} else {
  $error .= "Can not open $html_name (append). ";
  print STDERR "[$datestring] $service: ERROR: $error\n";
  error($error);
}

sleep(1); # make sure the files have been created and flushed

# REDIRECT TO THAT TEMPORARY FILE (this is our display)
$redirect="http://$server_name/ifit-web-services/upload/$name/index.html";
print $q->redirect($redirect); # this works (does not wait for script to end before redirecting)

sleep(5);

if (-e $html_name)  { unlink $html_name; } # remove that file which contains the token.

# WAIT for QEMU/noVNC to end ---------------------------------------------------
if ($proc_novnc) { $proc_novnc->wait; }

# normal end: remove lock
if (-e $lock_name)  { unlink $lock_name; }

sub error {
  print $q->header(-type=>'text/html');
  $q->start_html(-title=>"$service: Error [$fqdn]");
  $q->h3("$service: Error: $_[0]");
  $q->end_html;
  exit(0);
}

# CLEAN-UP temporary files (qcow2, html), proc_qemu, proc_novnc
END {
  print STDERR "[$datestring] $service: ended: QEMU $vm VNC=$qemuvnc_ip:5901 redirected to $novnc_port\n";
  if (-e $vm_name)    { unlink $vm_name; }
  if (-e $html_name)  { unlink $html_name; }
  if (-e $novnc_token) { unlink($token_name); }
  if (-e $base_name)  { rmdir  $base_name; } # in case auto-clean up fails
  if ($proc_novnc) { killfam($proc_novnc->pid); $proc_novnc->die; }
  # make sure QEMU and asssigned 'sh' are killed
  if ($proc_qemu)  { killfam('TERM',($proc_qemu->pid));  $proc_qemu->die; }
}

# ------------------------------------------------------------------------------

