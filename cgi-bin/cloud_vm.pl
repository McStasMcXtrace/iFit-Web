#!/usr/bin/perl -w

# requirements:
#   sudo apt-get install apache2 libapache2-mod-perl2 libcgi-pm-perl ifit-phonons libsys-cpu-perl libsys-cpuload-perl libnet-dns-perl libproc-background-perl
# sudo apt install qemu-kvm libvirt-clients libvirt-daemon-system bridge-utils libqcow2 qemu spice-html iptables dnsmasq
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
use Sys::CPU;         # libsys-cpu-perl
use Sys::CpuLoad;     # libsys-cpuload-perl
use Proc::Background; # libproc-background-perl
# ------------------------------------------------------------------------------
# service configuration: tune for your needs
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# GET and CHECK input parameters
# ------------------------------------------------------------------------------

$CGI::POST_MAX = 1024*5000; # max 5M upload

my $q = new CGI;    # create new CGI object
my $service="cloud_vm";
my $safe_filename_characters = "a-zA-Z0-9_.\-";

# configuration of the web service
my $upload_base= "/var/www/html";   # root of the HTML web server area
my $upload_dir = "$upload_base/ifit-web-services/upload"; # where to store results. Must exist.
my $novnc_client="$upload_base/ifit-web-services/Cloud/VirtualMachines/novnc/utils/launch.sh";

# testing computer load
my @cpuload = Sys::CpuLoad::load();
my $cpunb   = Sys::CPU::cpu_count();
my $cpuload0= $cpuload[0];

my $host         = hostname;
my $fqdn         = hostfqdn();
my $upload_short = $upload_dir;
$upload_short =~ s|$upload_base/||;

my $remote_ident=$q->remote_ident();
my $remote_host =$q->remote_host();
my $remote_addr =$q->remote_addr();
my $remote_user =$q->remote_user();
my $server_name =$q->server_name();
my $referer     =$q->referer();
my $user_agent  =$q->user_agent();
my $datestring  = localtime();
my $cmd         = "";

# used further, but defined here  so that END block works
my $vm_name     = "";
my $html_name   = "";
my $base_name   = "";
my $proc_novnc  = "";
my $proc_qemu   = "";

# both IP and PORT will be random in 0-254.
# a test is made to see if the port has already been allocated.
my $id = 0;
my $novnc_port  = 0;
my $lock        = "";
my $lock_name   = "";
my $qemuvnc_ip  = "";
my $id_ok       = 0;  # flag true when we found a non used IP/PORT
my $i           = 0;  # ID counter

# we try 10 times at most to search for suitable IP
for ($i=0; $i<=10; $i++) {
  $id          = int(rand(254));
  $novnc_port  = 6100 + $id;
  $lock        = "$service.$novnc_port";
  $lock_name   = "$upload_dir/$lock";
  $qemuvnc_ip  = "127.0.0.$id";
  if (not -e $lock_name) { $id_ok = 1; last; };  # exit loop if the ID is OK
}

# check for the existence of the IP:PORT pair.
if (not $id_ok) { 
  error("Can not assign unique ID $lock_name for session. Try again.");
}

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

if ($cpuload0 > 2.5*$cpunb) { 
  error("CPU load exceeded. Current=$cpuload0. Available=$cpunb. Try later (sorry).");
}

# testing/security
if (my $error = $q->cgi_error()){
  if ($error =~ /^413\b/o) {
    error("Maximum data limit exceeded.");
  }
  else {
    error("An unknown error has occured."); 
  }
}

# now get values of form parameters
my $vm       = $q->param('vm');   # 1- VM base name, must match a $vm.ova filename
if ( !$vm )
{
  error("There was a problem selecting the Virtual Machine.");
}

# check input file name
my ( $name, $path) = fileparse ( $vm );
$vm = $name;
$vm =~ tr/ /_/;
$vm =~ s/[^a-zA-Z0-9_.\-]//g; # safe_filename_characters
if ( $vm =~ /^([a-zA-Z0-9_.\-]+)$/ ) {
  $vm = $1;
} else {
  error("Virtual Machine file name contains invalid characters. Allowed: '$safe_filename_characters'");
}


# ------------------------------------------------------------------------------
# DO the work
# ------------------------------------------------------------------------------

# WE OPEN A TEMPORARY HTML DOCUMENT, WRITE INTO IT, THEN REDIRECT TO IT.
# The HTML document contains a meta redirect with delay, and some text.
# This way the cgi script can launch all and the web browser display is made independent
# (else only display CGI dynamic content when script ends).
$base_name = tempdir(TEMPLATE => "$service" . "_XXXXX", DIR => $upload_dir, CLEANUP => 1);

$html_name = $base_name . "/$service.html";
open(my $html_handle, '>', $html_name) or error("Could not create $html_name");
( $name, $path ) = fileparse ( $base_name );
# display welcome information in the temporary HTML file
my $redirect="http://$fqdn:$novnc_port/vnc.html?host=$fqdn&port=$novnc_port";

print $html_handle <<END_HTML;
<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">
<html>
<head>
  <meta http-equiv="refresh" content="60; URL=$redirect">
</head>
  <title>$service: $vm [$fqdn] (redirecting in 60 sec)</title>
</head>
<body>
  <img alt="iFit" title="iFit"
        src="http://ifit.mccode.org/images/iFit-logo.png"
        align="right" width="116" height="64">
  <img
          alt="SOLEIL" title="SOLEIL"
          src="http://ifit.mccode.org/images/logo_soleil.png"
          align="right" border="0" height="64">
  <h1>$service: Virtual Machines: $vm</h1>
  <img alt="virtualmachines" title="virtualmachines"
        src="http://$server_name/ifit-web-services/Cloud/VirtualMachines/images/virtualmachines.png" align="right" height="128" width="173">
  <p>Your machine $service $vm has just started. Open the following <a href=$redirect>link to display its screen</a> (click on the <b>Connect</b> button).</p>
  
  <p><b>IMPORTANT NOTES:</b><ul>
  <li>
   Remember that the virtual machine is created on request, and destroyed afterwards. You should then export any work done there-in elsewhere (e.g. mounted disk, ssh/sftp, Dropox, ...).</li>
  
  <li><b>When done, please shutdown the virtual machine properly</b> by selecting the 'Logout/Shutdown' button. 
  <b>Avoid</b> just closing the QEMU-noVNC $vm browser tab.</li>
  </ul>
  </p>
  <h1><a href=$redirect target=_blank>$redirect</a></h1>
  <br>This page will automatically open this link in 60 seconds.<br>
  <hr>
  <ul>
    <li>date: $datestring</li>
    <li><b>Service</b>: <a href="$referer" target="_blank">$fqdn/ifit-web-services</a> $service</li>
    <li><b>Status</b>: STARTED $datestring (current machine load: $cpuload0)</li>
    <li>host: $host $fqdn $server_name</li>
    <li>server_name: $server_name</li>
    <li>referer: $referer</li>
    <li>remote_ident: $remote_ident</li>
    <li>remote_host: $remote_host</li>
    <li>remote_addr: $remote_addr</li>
    <li>remote_user: $remote_user</li>
    <li>user_agent: $user_agent</li>
    <li>session ID: $lock_name</li>
  </ul>
  <hr>

</body>
</html>
END_HTML
close $html_handle;

# we create a lock file
open(my $lock_handle, '>', $lock_name) or error("Could not create $lock_name");
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

sleep(1); # make sure the files have been created and flushed

# NOW WE REDIRECT TO THAT TEMPORARY FILE (this is our display)
$redirect="http://$server_name/ifit-web-services/upload/$name/$service.html";
print $q->redirect($redirect); # this works (does not wait for script to end before redirecting)

# now send commands
# use 'upload' directory to store the temporary VM. 
# Keep it after creation so that the VM can run.

# set temporary VM file
$vm_name = $base_name . "/$service.qcow2";
my $res = "";

# CREATE SNAPSHOT FROM BASE VM IN THAT TEMPORARY FILE
sleep(1); # make sure the tmp file has been assigned
if (-e "$upload_dir/$vm.qcow2") {
  $cmd = "qemu-img create -b $upload_dir/$vm.qcow2 -f qcow2 $vm_name";
  $res = system($cmd);
} else {
  error("Virtual Machine $vm file does not exist on this server.");
}

# check for existence of cloned VM
sleep(1); # make sure the VM has been cloned
if (not -e $vm_name) {
  error("Could not clone Virtual Machine $vm_name.");
}

# LAUNCH NOVNC (do not wait for VNC to stop)
$cmd = "$novnc_client --vnc $qemuvnc_ip:5901 --listen $novnc_port";
$proc_novnc = Proc::Background->new($cmd);
if (not $proc_novnc) {
  error("Could not start noVNC.");
}

# LAUNCH CLONED VM with QXL video driver, KVM, and VNC, 4 cores
$cmd = "qemu-system-x86_64 -m 4096 -hda $vm_name -enable-kvm -smp 4 -net user -net nic,model=ne2k_pci -cpu host -boot c -vga qxl -vnc $qemuvnc_ip:1";
$proc_qemu = Proc::Background->new($cmd);
if (not $proc_qemu) {
  error("Could not start QEMU/VM $vm.");
}

$proc_qemu->wait;

# normal end: remove lock
if ($lock_name)  { unlink $lock_name; }
sleep(1);

# CLEAN-UP temporary files (qcow2, html), proc_qemu, proc_novnc
END {
  if ($vm_name)    { unlink $vm_name; }
  if ($html_name)  { unlink $html_name; }
  if ($base_name)  { rmdir  $base_name; } # in case auto-clean up fails
  if ($proc_novnc) { $proc_novnc->die; }
  if ($proc_qemu)  { $proc_qemu->die; }
}

# ------------------------------------------------------------------------------

sub error {
 # print $q->header(-type=>'text/html'),
       $q->start_html(-title=>"$service: Error [$fqdn]"),
       $q->h3("$service: Error: $_[0]"),
       $q->h4("$fqdn: Current machine load: $cpuload0"),
       $q->end_html;
 exit(0);
}
