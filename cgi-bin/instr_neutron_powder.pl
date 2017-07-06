#!/usr/bin/perl -w

# requirements:
#   sudo apt-get install apache2 libapache2-mod-perl2 libcgi-pm-perl ifit-web-services mcstas-suite libsys-cpu-perl libsys-cpuload-perl libnet-dns-perl

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

# ------------------------------------------------------------------------------
# GET and CHECK input parameters
# ------------------------------------------------------------------------------

$CGI::POST_MAX = 1024*5000; # max 5M upload

my $q = new CGI;    # create new CGI object
my $service="mcstas_neutron_powder";
my $safe_filename_characters = "a-zA-Z0-9_.-";

# configuration of the web service
my $upload_base= "/var/www/html";   # root of the HTML web server area
my $upload_dir = "$upload_base/ifit-web-services/upload"; # where to store results. Must exist.

# testing computer load
@cpuload = Sys::CpuLoad::load();
$cpunb   = Sys::CPU::cpu_count();
$cpuload0= @cpuload[0];

$host         = hostname;
$fqdn         = hostfqdn();
$upload_short = $upload_dir;
$upload_short =~ s|$upload_base/||;

$remote_ident=$q->remote_ident();
$remote_host =$q->remote_host();
$remote_addr =$q->remote_addr();
$referer     =$q->referer();
$user_agent  =$q->user_agent();
$datestring  = localtime();

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
my $lambda  = $q->param('lambda');  # 1- wavelength
my $DM      = $q->param('DM');      # 2- monochromator d-spacing
my $RM      = $q->param('RM');      # 3- monochromator curvature
my $ETA     = $q->param('ETA');     # 4- monochromator osaic
my $L1      = $q->param('L1');      # 5- source-monochromator distance
my $L2      = $q->param('L2');      # 6- monochromator-sample distance
my $L3      = $q->param('L3');      # 7- sample-detector distance
my $ALPHA1  = $q->param('ALPHA1');  # 8- 1st collimator
my $ALPHA2  = $q->param('ALPHA2');  # 9- 2nd collimator
my $ALPHA3  = $q->param('ALPHA3');  # 10- 3rd collimator
my $WS      = $q->param('WS');      # 11- sample size

my $raw            = "";  # additional options for sqw_phonons

if ( !$material )
{
  error("There was a problem uploading your file (try a smaller file).");
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
  error("Filename contains invalid characters. Allowed: '$safe_filename_characters'");
}

# use directory to store all results
$dir = tempdir(TEMPLATE => "mcstas_neutron_powder_XXXXX", DIR => $upload_dir);

# get a local copy of the input file
my $upload_filehandle = $q->upload("material");
open ( UPLOADFILE, ">$dir/$material" ) or error("$!");
binmode UPLOADFILE;
while ( <$upload_filehandle> )
{
  print UPLOADFILE;
}
close UPLOADFILE;

# test all parameter values (remove non safe chars)
$lambda  =~ s/[^$safe_email_characters]//g;
$DM      =~ s/[^$safe_email_characters]//g;
$RM      =~ s/[^$safe_email_characters]//g;
$ETA     =~ s/[^$safe_email_characters]//g;
$L1      =~ s/[^$safe_email_characters]//g;
$L2      =~ s/[^$safe_email_characters]//g;
$L3      =~ s/[^$safe_email_characters]//g;
$ALPHA1  =~ s/[^$safe_email_characters]//g;
$ALPHA2  =~ s/[^$safe_email_characters]//g;
$ALPHA3  =~ s/[^$safe_email_characters]//g;
$WS      =~ s/[^$safe_email_characters]//g;

$dir_short    = $dir;
$dir_short    =~ s|$upload_base/||;

# ------------------------------------------------------------------------------
# DO the work
# ------------------------------------------------------------------------------

# assemble calculation command lines
# launch the commands for the service

# first cif2hkl with material
"cif2hkl --powder -o $dir/powder.laz -l $lambda $dir/$material"

# then mcstas (in iFit).

"model=mccode('$upload_base/ifit-web-services/Downloads/templateDIFF.instr',struct('dir','$dir'))"  # must be accessible , in html/Downloads
"p.lambda=$lambda; p.DM=$DM; p.RM=$RM; p.ETA=$ETA; p.L1=$L1; p.L3=$L3; p.L2=$L2; p.ALPHA1=$ALPHA1; p.ALPHA2=$ALPHA2; p.ALPHA3=$ALPHA3; p.WS=$WS; model.UserData.Parameters_Constant.Powder='powder.laz'"
"model.UserData.options.monitors=''"  # get all monitors
"p=model(p, [], nan); p=model.UserData.monitors;"

# create static images (for display purposes)
"
save(p(1), '$dir/Diff_BananaTheta.png'); 
save(p(2), '$dir/Diff_BananaThetaPSD.png');
"

# create the 3D view
"
    [comps,fig] = mccode_display(model,[],'png eps pdf html tif fig');
    close(fig);
    exit
"

# then create html report with links to images, instrument, raw data...

# title: service, directory, date etc...
# instrument view (png and embedded xhtml)
# instrument configuration (parameters)
# diffractograms as png and raw .dat

# dump initial material file
$res = system("cat $dir/$material > $dir/ifit.log");

# the computation starts... 
$res = system("ifit -nodesktop \"$cmd\" >> $dir/ifit.log 2>&1");

# file used for monitoring the service usage
$filename = "$upload_dir/$service.html";

# display computation results
print $q->header ( );
print <<END_HTML;
  <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "DTD/xhtml1-strict.dtd">
  <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
  <head>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
  <title>$service: Thanks! [$fqdn]</title>
  <style type="text/css">
  img {border: none;}
  </style>
  </head>
  <body>
  <img alt="iFit" title="iFit"
        src="http://ifit.mccode.org/images/iFit-logo.png"
        align="right" width="116" height="64">
  <img
          alt="the ILL" title="the ILL"
          src="http://ifit.mccode.org/images/ILL-web-jpeg.jpg"
          align="right" border="0" width="68" height="64">
  <h1>$service: neutron powder diffratogram</h1>
  <p>Thanks for using our service <b>$service</b>
  <ul>
  <li><b>Service</b>: <a href="$referer" target="_blank">$fqdn/ifit-web-services</a> $service</li>
  <li><b>Input configuration</b>: <a href="http://$fqdn/$dir_short/$material" target="_blank">$material</a></li>
  <li><b>Command</b>: $cmd</li>
  <li><b>Status</b>: STARTED $datestring on $mpi cpu's (current machine load: $cpuload0)</li>
  <li><b>From</b>: $email $remote_addr
  </ul></p>
  <p>Results will be available on this server at <a href="http://$fqdn/$dir_short">$dir_short</a>.<br>
  You can now view:<ul>
  <li>a <a href="http://$fqdn/$dir_short/sqw_phonons.html" target="_blank">report on this calculation</a> to look at the current status and results.</li>
  <li>a <a href="http://$fqdn/$dir_short/" target="_blank">data files for this calculation</a>.</li>
  <li>the <a href="http://$fqdn/$dir_short/ifit.log" target="_blank">Log file</a>.</li>
  <li>the <a href="http://$fqdn/$upload_short/$service.html" target="_blank">report on the $service usage</a> (with current and past computations).</li>
  </ul>
  </p>
  <p>WARNING: Think about getting your data back upon completion, as soon as possible. There is no guaranty we keep it.</p>
END_HTML

if ($email ne "") {
  print <<END_HTML;
  <p>You should receive an email at $email when the computation ends.</p>
END_HTML
} else {
  print <<END_HTML;
  <p>Keep the reference <a href="http://$host/$dir_short" target="_blank">http://$host/$dir_short</a> safe 
  to be able to access your data when computation ends, as you will not be informed when it does. 
  Check regularly. In practice, the computation should not exceed a few hours for 
  most simple systems, but could be a few days for large ones (e.g. 50-100 atoms).</p>
END_HTML
}
print <<END_HTML;
  <hr>
  Powered by <a href="http://ifit.mccode.org" target="_blank">iFit</a> E. Farhi (c) 2016.<br>
  </body>
  </html>
END_HTML

# add an entry in the list of computations
if (not -f $filename) {
  # the table file does not exist. Create it
  open($fh, '>', $filename);
  printf $fh <<END_HTML;
  <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "DTD/xhtml1-strict.dtd">
  <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
  <head>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
  <title>$service: Usage report [$fqdn]</title>
  <style type="text/css">
  img {border: none;}
  </style>
  </head>
  <body>
  <img alt="iFit" title="iFit"
        src="http://ifit.mccode.org/images/iFit-logo.png"
        align="right" width="116" height="64">
  <img
          alt="the ILL" title="the ILL"
          src="http://ifit.mccode.org/images/ILL-web-jpeg.jpg"
          align="right" border="0" width="68" height="64">
  <h1><a href="http://$fqdn/ifit-web-services" target="_blank">$service</a>: usage</h1>
  This page reports on past and current computations.
  <ul>
    <li>machine: <a href="http://$fqdn/ifit-web-services" target="_blank">$fqdn</a></li>
    <li>service: $service</li>
    <li>allocated resources: $mpi cpu's</li>
  </ul>
  <table style="width:100%">
  <tr>
    <th>URL</th>
    <th>Material</th>
    <th>Calculator</th> 
    <th>User</th>
    <th>Options</th>
    <th>Log</th>
    <th>Start Date</th>
  </tr>
END_HTML
} else {
  open($fh, '>>', $filename);
}
printf $fh <<END_HTML;
  <tr>
    <td><a href="http://$fqdn/$dir_short/" target="_blank"><img src="http://$fqdn/$dir_short/Phonons3D.png" width="50" height="50"><img src="http://$fqdn/$dir_short/Phonons_DOS.png" width="50" height="50">$dir_short</a></td>
    <td><a href="http://$fqdn/$dir_short/$material" target="_blank"><img src="http://$fqdn/$dir_short/configuration.png" width="50" height="50">$material</a></td>
    <td>$calculator</td>
    <td><a href="mailto:$email">$email</a> from $remote_addr</td>
    <td>$raw occupations=$smearing<br>\nkpoints=$kpoints<br>\necut=$ecut<br>\nsupercell=$supercell</td>
    <td><a href="http://$fqdn/$dir_short/ifit.log" target="_blank">Log file</a></td>
    <td>$datestring</td>
  </tr>
END_HTML

close $fh;

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
         $q->start_html(-title=>"$service: Error [$fqdn]"),
         $q->h3("$service: Error: $_[0]"),
         $q->h4("$fqdn: Current machine load: $cpuload0"),
         $q->h4("<a href='http://$fqdn/$upload_short/$service.html'>Report on the $service usage</a> (with current and past computations)"),
         $q->end_html;
   exit(0);
}
