#!/usr/local/bin/perl

#
# this script accepts an image, resizes to specified maximum size
# and then puts links in the database refering to it
#


use strict;

use CGI qw/:standard/;
use DBI;

use JSON;

# load the configuration file
my $filename = "$ENV{RANGEPATH}/config/webconfig.json";

my $json_text = do {
    open(my $json_fh, "<:encoding(UTF-8)", $filename)
	or die("Can't open \"$filename\": $!\n");
    local $/;
    <$json_fh>
};

my $json = JSON->new;
my $data = $json->decode($json_text);

my $db_dsn = $data->{config}->{dsn} || die "no dsn specified";
my $db_username = $data->{config}->{dbusername} || die "no user specified";
my $db_password = $data->{config}->{dbpassword} || die "no user specified";

if( param ) {

    my $start = param('start');
    my $end = param('end');

    if( ! $end || $end eq '' ) {
	$end = '2100-01-01';
    }

    if( ! $start || $start eq '' ) {
	$start = '2014-01-01';
    }
    
    my $db = DBI->connect( $db_dsn, $db_username, $db_password );
    if( ! $db ) {
	print header( -type=>'text/plain',
		      -expires=>'+1m' );
	print "database problem". $DBI::errstr;
	exit;
    }
    $db->do( 'SET time_zone = "GMT"' );

    print header( -type=>'application/json',
		  -expires=>'+2m' );

    my $sth_station = $db->prepare( 'select o.station,lt,lg,status, '.
				    '  (select left(from_unixtime(max(time)),16) from availability_log al1 where al1.station_id = o.id) time, '.
				    '  (select count(*) from availability_log al where al.station_id = o.id and al.time > unix_timestamp() - 3600*24) bounces '.
				    '  from stations o left join availability a on o.id = a.station_id, '.
				    '   stationlocation sl where  o.id = sl.station and '.
				    '   sl.time=(select max(i.time) from stationlocation i where i.station=o.id and i.time between ? and ?) '.
				    ' order by time desc, station asc' );

    $sth_station->execute( $start, $end );
	 
    print '{"stations":[';
    
    my $rows = []; # cache for batches of rows
    my $count = 0;
    while( my $row = ( shift(@$rows) || # get row from cache, or reload cache:
		       shift(@{$rows=$sth_station->fetchall_arrayref(undef,10_000)||[]}) )
	) {

	if( $count ) {
	    print ',';
	}
	$count++;

	if( ! defined($row->[3]) ) {
	    $row->[3] = 'D';
	}

	printf( '{"s":"%s","lt":%.4f,"lg":%.4f,"u":"%s","ut":"%s","b":%d}', @{$row} );
    }

    print ']}';
	     
}
