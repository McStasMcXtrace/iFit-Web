#!/usr/bin/perl -w

# requirements:
#   sudo apt-get install apache2 libapache2-mod-perl2 libcgi-pm-perl ifit-phonons libsys-cpu-perl libsys-cpuload-perl libnet-dns-perl

# ensure all fatals go to browser during debugging and set-up
# comment this BEGIN block out on production code for security
BEGIN {
    $|=1;
    use CGI::Carp('fatalsToBrowser');
}

use CGI;            # use CGI.pm
use File::Temp qw/ tempfile tempdir /;
use IO::Compress::Zip qw(zip $ZipError) ;
use IPC::Open3;
use File::Basename;
use Net::Domain qw(hostname hostfqdn);
use Sys::CPU;     # libsys-cpu-perl
use Sys::CpuLoad; # libsys-cpuload-perl
use Socket;
use POSIX ":sys_wait_h"; # for fork/exec/waitpid
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
my $referer     =$q->referer();
my $user_agent  =$q->user_agent();
my $datestring  = localtime();

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
my ( $name, $path, $extension ) = fileparse ( $vm, '..*' );
$vm = $name . $extension;
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

# display welcome information
print $q->header ( );
print <<END_HTML;
  <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "DTD/xhtml1-strict.dtd">
  <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
  <head>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
  <title>$service: $vm [$fqdn]</title>
  <style type="text/css">
  img {border: none;}
  </style>
  </head>
  <body>
  <img alt="iFit" title="iFit"
        src="http://ifit.mccode.org/images/iFit-logo.png"
        align="right" width="116" height="64">
  <img
          alt="the SOLEIL Synchrotron" title="SOLEIL"
          src="http://ifit.mccode.org/images/logo-soleil.png"
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
  <p>Sending commands...</p>
END_HTML

# now send commands
# use 'upload' directory to store the temporary VM. 
# Keep it after creation so that the VM can run.

# create ytemporary VM file
my $vm_copy = File::Temp->new(TEMPLATE => "cloud_vm_XXXXX", DIR => $upload_dir, SUFFIX => ".qcow2", UNLINK => 0);
print "<p><b>Creating</b>: $vm_copy</p>";
my $res = "";

# create snapshot from base VM in that temporary file
sleep(1); # make sure the tmp file has been assigned
if (-e "$upload_dir/$vm.qcow2") {
  print "<p><b>Cloning</b>: qemu-img create -b  $upload_dir/$vm.qcow2 -f qcow2 $vm_copy<br></p>";
  $res = system("qemu-img create -b $upload_dir/$vm.qcow2 -f qcow2 $vm_copy");
  print "<p>Result: $res</p>";
} else {
  error("Virtual Machine $vm file does not exist on this server.");
}

# check for existence of cloned VM
sleep(1); # make sure the VM has been cloned
if (not -e $vm_copy) {
  error("Virtual Machine $vm could not be cloned.");
}

# launch cloned VM
# we use a fork/exec/waitpid to distribute execution on threads and catch end of execution (for clean-up)
if (my $pid_qemu = fork) {
  sleep(5); # wait for qemu child to start
  # we fork again to start noVNC, but do not wait for it to stop. We shall kill it at cleanup
  if (my $pid_novnc = fork) { 
    # go to the waitpid qemu...
  } else {
    # child: pid_novnc
    print "<p><b>Launching</b>: $novnc_client --vnc $qemuvnc_ip:5901 --listen $novnc_port<br></p>";
    print "OPEN: <a href=http://$fqdn:$novnc_port/vnc.html?host=$fqdn&port=$novnc_port target=_blank>http://$fqdn:$novnc_port/vnc.html?host=$fqdn&port=$novnc_port</a></p>";
    exec("$novnc_client --vnc $qemuvnc_ip:5901 --listen $novnc_port");
  }

  # parent: wait for end
  # waitpid($pid_qemu, 0);
  # parent: child qemu ended: clean-up
  
} else {
  # child: pid_qemu
  print "<p><b>Launching</b>: qemu-system-x86_64-spice -m 4096 -hda $vm_copy -enable-kvm -no-acpi -smp 4 -net user -net nic,model=ne2k_pci -cpu host -boot c -vnc $qemuvnc_ip:1<br></p>";
  exec("qemu-system-x86_64 -m 4096 -hda $vm_copy -enable-kvm -no-acpi -smp 4 -net user -net nic,model=ne2k_pci -cpu host -boot c -vnc $qemuvnc_ip:1");
}

# clean-up: temporary file, pid_qemu, pid_novnc
print "Cleaning-up...<br>";

print <<END_HTML;
  </body>
  </html>
END_HTML
# ------------------------------------------------------------------------------

 sub error {
   print $q->header(-type=>'text/html'),
         $q->start_html(-title=>"$service: Error [$fqdn]"),
         $q->h3("$service: Error: $_[0]"),
         $q->h4("$fqdn: Current machine load: $cpuload0"),
         $q->end_html;
   exit(0);
}
