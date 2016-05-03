#!/usr/bin/perl -w

# requirements:
#   sudo apt-get install apache2 libapache2-mod-perl2 libcgi-pm-perl ifit-phonons

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
use Sys::Hostname;
use Sys::CPU;     # libsys-cpu-perl
use Sys::CpuLoad; # libsys-cpuload-perl


# ------------------------------------------------------------------------------
# GET and CHECK input parameters
# ------------------------------------------------------------------------------

$CGI::POST_MAX = 1024*5000; # max 5M upload

my $q = new CGI;    # create new CGI object
my $service="sqw_phonons";
my $safe_filename_characters = "a-zA-Z0-9_.-";
my $safe_email_characters     = "a-zA-Z0-9_.-@";
my $host = hostname();

# configuration of the web service
my $upload_base= "/var/www/html";   # root of the HTML web server area
my $upload_dir = "$upload_base/ifit-web-services/upload"; # where to store results. Must exist.
my $mpi        = "4";  # number of core/cpu's to allocate to the service. 1 is serial. Requires OpenMPI.

# testing computer load
$cpuload = Sys::CpuLoad::load();
$cpunb   = Sys::CPU::cpu_count();

if ($cpuload > $cpunb) { 
  error("$service: CPU load exceeded. Current=$cpuload. Available=$cpunb. Try later (sorry).");
}


# testing/security
if (my $error = $q->cgi_error()){
  if ($error =~ /^413\b/o) {
    error("$service: Maximum data limit exceeded.");
  }
  else {
    error("$service: An unknown error has occured."); 
  }
}

# now get values of form parameters
my $material       = $q->param('material');   # 1- Material structure
my $calculator     = $q->param('calculator'); # 2- Indicate the calculator
my $smearing       = $q->param('smearing');   # 3- Indicate if the material is a conductor or insulator
my $ecut           = $q->param('ecut');       # 4- Indicate the energy cut-off
my $kpoints        = $q->param('kpoints');    # 5- Indicate the K-points
my $supercell      = $q->param('supercell');  # 6- Indicate the supercell size
my $email          = $q->param('email');      # 7- Indicate your email


if ( !$material )
{
  error("$service: There was a problem uploading your file (try a smaller file).");
}

# check input file name
my ( $name, $path, $extension ) = fileparse ( $material, '..*' );
$material = $name . $extension;
$material =~ tr/ /_/;
$material =~ s/[^$safe_filename_characters]//g;
if ( $material =~ /^([$safe_filename_characters]+)$/ )
{
  $material = $1;
}
else
{
  error("$service: Filename contains invalid characters. Allowed: '$safe_filename_characters'");
}

# check email
$email =~ s/[^$safe_email_characters]//g;
if ( $email =~ /^([$safe_email_characters]+)$/ )
{
  $email = $1;
}
else
{
  $email="";
}

# use directory to store all results
$dir = tempdir(TEMPLATE => "sqw_phonons_XXXXX", DIR => $upload_dir);

# get a local copy of the input file
my $upload_filehandle = $q->upload("material");
open ( UPLOADFILE, ">$dir/$material" ) or error("$!");
binmode UPLOADFILE;
while ( <$upload_filehandle> )
{
  print UPLOADFILE;
}
close UPLOADFILE;

# test: smearing="metal","insulator","semiconductor"
if ($smearing ne "metal" and $smearing ne "insulator" and $smearing ne "semiconductor") {
  $smearing = "metal";
}
# test: ecut    =260 340 500 1000 1500
if ($ecut ne "260" and $ecut ne "340" and $ecut ne "500"  and $ecut ne "1000" and $ecut ne "1500") {
  $ecut = "340";
}
# test: kpoints =2 3 4
if ($kpoints ne "2" and $kpoints ne "3" and $kpoints ne "4") {
  $kpoints = "3";
}
# test: supercell=2 3 4
if ($supercell ne "2" and $supercell ne "3" and $supercell ne "4") {
  $supercell = "2";
}
# test: calculator=EMT,QuantumEspresso,ABINIT,GPAW,ELK,VASP
if ($calculator ne "EMT" and $calculator ne "QuantumEspresso" and $calculator ne "ABINIT"  and $calculator ne "GPAW" and $calculator ne "ELK" and $calculator ne "VASP") {
  $calculator = "QuantumEspresso";
}

# ------------------------------------------------------------------------------
# DO the work
# ------------------------------------------------------------------------------

# assemble command line
if ($email ne "") {
  $cmd = "'try;sqw_phonons('$dir/$material','$calculator','occupations=$smearing;kpoints=$kpoints;ecut=$ecut;supercell=$supercell;email=$email;mpi=$mpi;target=$dir','report');catch ME;disp('Error when executing sqw_phonons');disp(getReport(ME));end;exit'";
} else {
  $cmd = "'try;sqw_phonons('$dir/$material','$calculator','occupations=$smearing;kpoints=$kpoints;ecut=$ecut;supercell=$supercell;mpi=$mpi;target=$dir','report');catch ME;disp('Error when executing sqw_phonons');disp(getReport(ME));end;exit'";
}

# launch the command for the service

# dump initial material file
$res = system("cat $dir/$source > $dir/ifit.log");
$res = system("ifit \"$cmd\" >> $dir/ifit.log 2>&1 &");

$dir_short = $dir;
$dir_short =~ s|$upload_base/||;

$remote_ident=$q->remote_ident();
$remote_host =$q->remote_host();
$remote_addr =$q->remote_addr();
$referer     =$q->referer();
$user_agent  =$q->user_agent();

# display computation results
print $q->header ( );
print <<END_HTML;
  <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "DTD/xhtml1-strict.dtd">
  <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
  <head>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
  <title>$service: Thanks!</title>
  <style type="text/css">
  img {border: none;}
  </style>
  </head>
  <body>
  <h1>$service: Phonon dispersions in 4D</h1>
  <p>Thanks for using our service <b>$service</b>
  <ul>
  <li>Service URL: <a href="$referer">$host/ifit-web-services</a></li>
  <li>Command: $cmd</li>
  <li>Status: STARTED</li>
  <li>From: $remote_addr
  </ul></p>
  <p>Results will be available on this server at <a href="http://$host/$dir_short">$dir_short</a>.<br>
  You will find:<ul>
  <li>a <a href="http://$host/$dir_short/index.html">full report</a> to look at the current status of the computation.<a/li>
  <li>the <a href="http://$host/$dir_short/ifit.log">Log file</a>.</li></ul>
  </p>
  <p>WARNING: Think about getting your data back upon completion,as soon as possible. There is no guaranty we keep it.</p>
END_HTML

if ($email ne "") {
  print <<END_HTML;
  <p>You should receive an email at $email now, and when the computation ends.</p>
END_HTML
} else {
  print <<END_HTML;
  <p>Keep the reference <a href="http://$host/$dir_short">http://$host/$dir_short</a> safe 
  to be able to access your data when computation ends, as you will not be informed when it does. 
  Check regularly. In practice, the computation should not exceed a few hours for 
  most simple systems, but could be a few days for large ones (e.g. 50-100 atoms).</p>
END_HTML
}
print <<END_HTML;
  <hr>
  Powered by <a href="http://ifit.mccode.org">iFit</a> E. Farhi (c) 2016.<br>
  </body>
  </html>
END_HTML

# -----------------------------------------------------------
 sub download {
   my $file = $_[0] or return(0);
 
   # Uncomment the next line only for debugging the script 
   #open(my $DLFILE, '<', "$path_to_files/$file") or die "Can't open file '$path_to_files/$file' : $!";
 
   # Comment the next line if you uncomment the above line 
   open(my $DLFILE, '<', "$file") or return(0);
   $base = basename($file);
   # this prints the download headers with the file size included
   # so you get a progress bar in the dialog box that displays during file downloads. 
   print $q->header(-type            => 'application/x-download',
                    -attachment      => $file,
                    -Content_length  => -s "$file",
   );
 
   binmode $DLFILE;
   print while <$DLFILE>;
   undef ($DLFILE);
   $q->end_html;
   return(1);
}

 sub error {
   print $q->header(-type=>'text/html'),
         $q->start_html(-title=>'Error'),
         $q->h3("ERROR: $_[0]"),
         $q->end_html;
   exit(0);
}
