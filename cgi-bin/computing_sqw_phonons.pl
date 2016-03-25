#!/usr/bin/perl -w

# requirements:
#   sudo apt-get install apache2 libapache2-mod-perl2 libcgi-pm-perl ifit-phonons

# ensure all fatals go to browser during debugging and set-up
# comment this BEGIN block out on production code for security
#BEGIN {
#    $|=1;
#    use CGI::Carp('fatalsToBrowser');
#}

use CGI;            # use CGI.pm
use File::Temp qw/ tempfile tempdir /;
use IO::Compress::Zip qw(zip $ZipError) ;
use IPC::Open3;
use File::Basename;

# ------------------------------------------------------------------------------
# GET and CHECK input parameters
# ------------------------------------------------------------------------------

$CGI::POST_MAX = 1024*5000; # max 5M upload

my $q = new CGI;    # create new CGI object
my $service="sqw_phonons";
my $safe_filename_characters = "a-zA-Z0-9_.-";
my $safe_email_characters     = "a-zA-Z0-9_.-@";
my $upload_dir = "/var/www/html/upload";

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


if ( !$source )
{
  print $q->header ( );
  print "$service: There was a problem uploading your file (try a smaller file).";
  exit;
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
  die "$service: Filename contains invalid characters.";
}

if ( !$email )
{
  print $q->header ( );
  print "$service: There was a problem with your email. Did you specify it ?.";
  exit;
}

# check email
$email =~ s/[^$safe_email_characters]//g;
if ( $email =~ /^([$safe_email_characters]+)$/ )
{
  $email = $1;
}
else
{
  die "$service: email contains invalid characters.";
}

# use temporary directory to store all results
$dir = tempdir(TEMPLATE => "sqw_phonons_XXXXX", DIR => $upload_dir, CLEANUP => 1);

# get a local copy of the input file
my $upload_filehandle = $q->upload("material");
open ( UPLOADFILE, ">$dir/$source" ) or die "$!";
binmode UPLOADFILE;
while ( <$upload_filehandle> )
{
  print UPLOADFILE;
}
close UPLOADFILE;

# ------------------------------------------------------------------------------
# DO the work
# ------------------------------------------------------------------------------

# assemble command line
if ($probe ne "NUC" and $probe ne "ELE" and $probe ne "XRA") {
  $probe = "NUC";
}

if ($phase ne "powder" and $phase ne "xtal") {
  $phase = "powder";
}

# launch the command for the service
# assemble command line
$res = system("cif2hkl --version > $dir/cif2hkl.log");
# dump initial CIF file
$res = system("cat $dir/$source >> $dir/cif2hkl.log");
$res = system("$service --verbose --$phase --mode $probe --out $dir/reflections.$phase $dir/$source >> $dir/cif2hkl.log");

# now collect the results: compress the output directory
zip "<$dir/*>" => "$dir.zip", 
              FilterName => sub { s[^$dir/][] }, 
              Comment    => "$service $cmd_target $cmd_type $dir/$source $dir"
            or error("$service: Error compressing '$dir': $ZipError\n");

download("$dir.zip");

# display conversion results: not shown with download which also writes a binary HTML stream
print $q->header ( );
print <<END_HTML;
  <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "DTD/xhtml1-strict.dtd">
  <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
  <head>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
  <title>Thanks!</title>
  <style type="text/css">
  img {border: none;}
  </style>
  </head>
  <body>
  <p>Thanks for using our service</p>
  <p>Command: $service --verbose --$phase --mode $probe --out $dir/reflections.$phase $dir/$source<p>
  <p>Status: DONE</p>
  </body>
  </html>
END_HTML

unlink("$dir.zip");

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
         $q->h3("$service: Error: $_[0]"),
         $q->end_html;
   exit(0);
}
