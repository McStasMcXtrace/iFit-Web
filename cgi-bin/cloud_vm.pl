#!/usr/bin/perl -w

# requirements:
#   sudo apt-get install apache2 libapache2-mod-perl2 libcgi-pm-perl ifit-phonons libsys-cpu-perl libsys-cpuload-perl libnet-dns-perl libproc-background-perl

# ensure all fatals go to browser during debugging and set-up
# comment this BEGIN block out on production code for security
BEGIN {
    $|=1;
    use CGI::Carp('fatalsToBrowser');
}

use CGI;            # use CGI.pm
use File::Temp qw/ tempfile tempdir /;
use Net::Domain qw(hostname hostfqdn);
use File::Basename qw(fileparse);
use Sys::CPU;     # libsys-cpu-perl
use Sys::CpuLoad; # libsys-cpuload-perl
use Proc::Background;
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

# we count how many instances are already opened
my @stuff = glob( "$upload_dir/*." );
my $id = 1 + scalar @stuff;
my $novnc_port = 6080+$id;        # assigned dynamically
my $qemuvnc_ip = "127.0.0.$id";   # assigned dynamically

# testing computer load
my @cpuload = Sys::CpuLoad::load();
my $cpunb   = Sys::CPU::cpu_count();
my $cpuload0= @cpuload[0];

my $host         = hostname;
my $fqdn         = hostfqdn();
my $upload_short = $upload_dir;
my $upload_short =~ s|$upload_base/||;

my $remote_ident=$q->remote_ident();
my $remote_host =$q->remote_host();
my $remote_addr =$q->remote_addr();
my $remote_user =$q->remote_user();
my $server_name =$q->server_name();
my $referer     =$q->referer();
my $user_agent  =$q->user_agent();
my $datestring  = localtime();
my $cmd         = "";

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
my $base_name = File::Temp->new(TEMPLATE => "cloud_vm_XXXXX", DIR => $upload_dir, UNLINK => 1);

my $html_name = $base_name . ".html";
open(my $html_handle, '>', $html_name) or error("Could not create $html_name");
( $name, $path ) = fileparse ( $html_name );
# display welcome information in the temporary HTML file
my $redirect="http://$fqdn:$novnc_port/vnc.html?host=$fqdn&port=$novnc_port";

print $html_handle <<END_HTML;
<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">
<html>
<head>
  <meta http-equiv="refresh" content="5; URL=$redirect">
</head>
  <title>$service: $vm [$fqdn] (redirecting in 5 sec)</title>
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
  <p>Thanks for using our service <b>$service</b>
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
  </ul>
  <hr>

Now redirecting to<br>
<h1><a href=$redirect target=_blank>$redirect</a></h1>
<br>in (5 sec)...
</body>
</html>
END_HTML

close $html_handle;
sleep(1); # make sure the file has been created and flushed

# NOW WE REDIRECT TO THAT TEMPORARY FILE (this is our display)
$redirect="http://$server_name/ifit-web-services/upload/$name";
print $q->redirect($redirect); # this works (does not wait for script to end before redirecting)

# now send commands
# use 'upload' directory to store the temporary VM. 
# Keep it after creation so that the VM can run.

# set temporary VM file
my $vm_name = $base_name . ".qcow2";
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
my $proc_novnc = Proc::Background->new($cmd);
if (not $proc_novnc) {
  error("Could not start noVNC.");
}

# LAUNCH CLONED VM with QXL video driver, KVM, and VNC, 4 cores
$cmd = "qemu-system-x86_64 -m 4096 -hda $vm_name -enable-kvm -smp 4 -net user -net nic,model=ne2k_pci -cpu host -boot c -vga qxl -vnc $qemuvnc_ip:1";
my $proc_qemu = Proc::Background->new($cmd);
if (not $proc_qemu) {
  error("Could not start QEMU/VM $vm.");
}

# we write a script that lists all clean-ups for automatic/daemon tasks
my $clean_name = $base_name . ".sh";
open(my $clean_handle, '>', $clean_name) or error("Could not create $clean_name");
my $pid_qemu  = $proc_qemu->pid;
my $pid_novnc = $proc_novnc->pid;
print $clean_handle "#!/bin/sh\n#\n";
print $clean_handle "# clean up script for virtual machine $vm\n";
print $clean_handle "# started        $datestring\n";
print $clean_handle "# referer        $referer\n";
print $clean_handle "# fqdn           $fqdn/ifit-web-services\n";
print $clean_handle "# machine load   $cpuload0\n";
print $clean_handle "# server         $fqdn $host $fqdn $server_name\n";
print $clean_handle "# server_name    $server_name\n";
print $clean_handle "# remote_ident   $remote_ident\n";
print $clean_handle "# remote_host    $remote_host\n";
print $clean_handle "# remote_addr    $remote_addr\n";
print $clean_handle "# remote_user    $remote_user\n";
print $clean_handle "# user_agent     $user_agent\n\n";
print $clean_handle "# novnc_port     $novnc_port\n";
print $clean_handle "# vnc            $qemuvnc_ip:5901\n";
print $clean_handle "# qcow2 command  qemu-img create -b $upload_dir/$vm.qcow2 -f qcow2 $vm_name\n";
print $clean_handle "# qemu command   $cmd\n";
print $clean_handle "# novnc command  $novnc_client --vnc $qemuvnc_ip:5901 --listen $novnc_port\n";
print $clean_handle "# \n";
print $clean_handle "rm -f $base_name\n";
print $clean_handle "rm -f $vm_name\n";
print $clean_handle "rm -f $html_name\n";
print $clean_handle "rm -f $clean_name\n";
print $clean_handle "kill -9 -$pid_novnc -$pid_qemu -$$\n";
close $clean_handle;
chmod 0755, $clean_name;

$proc_qemu->wait;

open(my $clean_handle, '>>', $clean_name) or error("Could not open $clean_name");
print $clean_handle "# ended " . localtime();
close $clean_handle;
sleep(1);
system($clean_name);

# CLEAN-UP temporary files (qcow2, html), proc_qemu, proc_novnc
$proc_novnc->die;


# ------------------------------------------------------------------------------

sub error {
 # print $q->header(-type=>'text/html'),
       $q->start_html(-title=>"$service: Error [$fqdn]"),
       $q->h3("$service: Error: $_[0]"),
       $q->h4("$fqdn: Current machine load: $cpuload0"),
       $q->end_html;
 exit(0);
}
