#!/usr/bin/perl -w

# requirements:
#   sudo apt-get install apache2 libapache2-mod-perl2 libcgi-pm-perl ifit-phonons libsys-cpu-perl libsys-cpuload-perl libnet-dns-perl libproc-background-perl


# NOTE  this one nearly works. See https://www.unix.com/shell-programming-and-scripting/142242-perl-cgi-no-output-until-backend-script-done.html
# to flush HTML output as it comes...

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
my $novnc_port = 6080;        # should be assigned dynamically
my $qemuvnc_ip = "127.0.0.2"; # should be assigned dynamically

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

# we open a temporary HTML document, write into it, then redirect to it.
# The HTML document contains a meta redirect with delay, and some text.

my $html = File::Temp->new(TEMPLATE => "cloud_vm_XXXXX", DIR => $upload_dir, SUFFIX => ".html", UNLINK => 1);
( $name, $path ) = fileparse ( $html );
# display welcome information in the temporary HTML file
my $redirect="http://$fqdn:$novnc_port/vnc.html?host=$fqdn&port=$novnc_port";

print $html <<END_HTML;
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
    <li><b>Service</b>: <a href="$referer" target="_blank">$fqdn/ifit-web-services</a> $service</li>
    <li><b>Status</b>: STARTED $datestring (current machine load: $cpuload0)</li>
    <li>host: $host</li>
    <li>remote_ident: $remote_ident</li>
    <li>remote_host: $remote_host</li>
    <li>remote_addr: $remote_addr</li>
    <li>referer: $referer</li>
    <li>user_agent: $user_agent</li>
    <li>date: $datestring</li>
    <li>$fqdn: Current machine load: $cpuload0</li>
  </ul>
  <hr>

Now redirecting to<br>
<h1><a href=$redirect target=_blank>$redirect</a></h1>
<br>in (5 sec)...
</body>
</html>
END_HTML

close $html;
sleep(1); # make sure the file has been created and flushed

# now we redirect to that temporary file
$redirect="http://localhost/ifit-web-services/upload/$name";
print $q->redirect($redirect); # this works (does not wait for script to end before redirecting)

# now send commands
# use 'upload' directory to store the temporary VM. 
# Keep it after creation so that the VM can run.

# create temporary VM file
my $vm_copy = File::Temp->new(TEMPLATE => "cloud_vm_XXXXX", DIR => $upload_dir, SUFFIX => ".qcow2", UNLINK => 1);
my $res = "";

# create snapshot from base VM in that temporary file
sleep(1); # make sure the tmp file has been assigned
if (-e "$upload_dir/$vm.qcow2") {
  $cmd = "qemu-img create -b $upload_dir/$vm.qcow2 -f qcow2 $vm_copy";
  $res = system($cmd);
} else {
  error("Virtual Machine $vm file does not exist on this server.");
}

# check for existence of cloned VM
sleep(1); # make sure the VM has been cloned
if (not -e $vm_copy) {
  error("Could not clone Virtual Machine $vm.");
}

# do not wait for VNC to stop
$cmd = "$novnc_client --vnc $qemuvnc_ip:5901 --listen $novnc_port";
my $pid_novnc = Proc::Background->new($cmd);
if (not $pid_novnc) {
  error("Could not start noVNC.");
}

# launch cloned VM
$cmd = "qemu-system-x86_64 -m 4096 -hda $vm_copy -enable-kvm -smp 4 -net user -net nic,model=ne2k_pci -cpu host -boot c -vnc $qemuvnc_ip:1";
my $pid_qemu = Proc::Background->new($cmd);
if (not $pid_qemu) {
  error("Could not start QEMU/VM $vm.");
}

$pid_qemu->wait;

# clean-up: temporary files (qcow2, html), pid_qemu, pid_novnc
$pid_novnc->die;

# ------------------------------------------------------------------------------

sub error {
 # print $q->header(-type=>'text/html'),
       $q->start_html(-title=>"$service: Error [$fqdn]"),
       $q->h3("$service: Error: $_[0]"),
       $q->h4("$fqdn: Current machine load: $cpuload0"),
       $q->end_html;
 exit(0);
}
