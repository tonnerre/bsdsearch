#!/usr/pkg/bin/perl -w
#
# (c) 2007, Caoimhe Chaos <caoimhechaos@protonmail.com>,
#	    SyGroup GmbH Reinach. All rights reserved.
#
# Redistribution and use  in source and binary forms,  with or without
# modification, are  permitted provided that  the following conditions
# are met:
#
# * Redistributions  of source  code must  retain the  above copyright
#   notice, this list of conditions and the following disclaimer.
# * Redistributions in binary form  must reproduce the above copyright
#   notice, this  list of conditions  and the following  disclaimer in
#   the  documentation  and/or   other  materials  provided  with  the
#   distribution.
# * Neither  the  name  of  the  SyGroup  GmbH nor  the  name  of  its
#   contributors may  be used to  endorse or promote  products derived
#   from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED  BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES OF MERCHANTABILITY AND
# FITNESS FOR A  PARTICULAR PURPOSE ARE DISCLAIMED. IN  NO EVENT SHALL
# THE  COPYRIGHT  OWNER OR  CONTRIBUTORS  BE  LIABLE  FOR ANY  DIRECT,
# INDIRECT, INCIDENTAL,  SPECIAL, EXEMPLARY, OR  CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT  NOT LIMITED TO, PROCUREMENT OF  SUBSTITUTE GOODS OR
# SERVICES; LOSS  OF USE, DATA, OR PROFITS;  OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY  THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT  LIABILITY,  OR  TORT  (INCLUDING  NEGLIGENCE  OR  OTHERWISE)
# ARISING IN ANY WAY OUT OF  THE USE OF THIS SOFTWARE, EVEN IF ADVISED
# OF THE POSSIBILITY OF SUCH DAMAGE.
#

use lib qw(../lib);
use Bsdprojects::Search::Filter;
use Bsdprojects::Search::UTF8;
use LWP::UserAgent;
use HTTP::Cookies;
use Time::HiRes qw(time);
use List::MoreUtils qw(uniq apply);
use strict;
use utf8;
use URI;

use Bsdprojects::Search::Schema;

my $schema = Bsdprojects::Search::Schema->connect(
	"dbi:Pg:dbname=searchengine", $ARGV[0], $ARGV[1], {}
) or die('Unable to connect to database');

sub index_site
{
	my ($ua, $obj) = @_;
	my $url = $obj->url;
	my @sitewords;
	my @uniquewords;
	my $sites;
	my $ref = {};
	my $req;
	my $res;
	my $ctype;
	my $links;
	my $cnt;
	my $authority = 0;
	my $start;

	$url =~ s/#.*$//g;

	$start = time();
	$req = new HTTP::Request(HEAD => $url);
	$res = $ua->request($req);

	unless ($res->is_success)
	{
		eval {
			$obj->failed(1);
			$obj->update;
		};
		return 0;
	}

	print("Updating " . $url . "\n");

	$ctype = $res->header('Content-type');

	unless (defined($ctype))
	{
		eval {
			$obj->failed(1);
			$obj->update;
		};
		return 0;
	}

	$ctype =~ s/[;,].*$//g;
	$ctype =~ s/\W/ /g;
	$ctype =~ s/(\w+)/ucfirst($1)/eg;
	$ctype =~ s/\s//g;

	eval("use Bsdprojects::Search::Filter::$ctype;\n" .
		"bless(\$ref, 'Bsdprojects::Search::Filter::$ctype');");
	if ($@)
	{
		# warn('Unable to load content parser: ' . $@);
		eval {
			$obj->failed(1);
			$obj->update;
		};
		return 0;
	}

	$req = new HTTP::Request(GET => $url);
	$res = $ua->request($req);

	unless ($res->is_success)
	{
		eval {
			$obj->failed(1);
			$obj->update;
		};
		return 0;
	}

	$cnt = u8ify($res->content);

	eval {
		$obj->abstract($ref->parse($cnt));
		$obj->title($ref->title($cnt));
		$obj->lastindex('now');
		$obj->update;
	};
	if ($@)
	{
		eval {
			$obj->discard_changes();
			$obj->failed(1);
			$obj->update;
		};
		return 0;
	}
	$links = $ref->refs($res->content, $url);

	foreach my $link (@{$links})
	{
		$link = URI->new($link)->canonical;
		$link->fragment(undef);
		$link->path('/') unless (defined($link->path) && length($link->path));
		$link = $link->as_string;

		unless ($link =~ /^mailto:/ || $link =~ /^irc:/)
		{
			my $encurl = $url;
			my @urlparts = split("/", $url);
			my $loop = 0;
			$encurl =~ s/([^\w\-\+\.])/sprintf("%%%02X",ord($1))/eg;

			foreach my $part (uniq @urlparts)
			{
				$loop = 1 if (scalar(grep { $_ eq $part }
					@urlparts) > 3);
			}

			$loop = 1 if ($link =~ /=$encurl/ ||
				$link =~ /%252525/);

			# Avoid loops
			unless ($loop)
			{
				my $site = $schema->resultset('Website')->
					find_or_create({url =>	$link});
				$schema->resultset('Linksto')->
					find_or_create({
					id_from =>	$obj->id,
					id_to =>	$site->id
				});
			}
			else
			{
				print($link . ' looks like an URL loop, ' .
					"skipping.\n");
			}
		}
	}

	@sitewords = split(/\W+/, $obj->abstract);

	$obj->spamminess(int(scalar(@{$links}) * 1000 / scalar(@sitewords)))
		if (scalar(@sitewords));

	@uniquewords = uniq(apply { $_ = lc($_) } grep { length($_) > 2 }
		@sitewords);
	printf("Saved %.01f%% spotting duplicates.\n",
		(scalar(@sitewords) > 0 ?
		 ((scalar(@sitewords) - scalar(@uniquewords)) * 100) /
		 scalar(@sitewords) : 0));
	foreach my $word (@uniquewords)
	{
		my $dbword = $schema->resultset('Keyword')->
			find_or_create({word =>	lc($word)});
		my $count = scalar(grep { lc($_) eq lc($word) } @sitewords);
		$schema->resultset('Siteword')->
			update_or_create({
			id_keyword =>	$dbword->id,
			id_site =>	$obj->id,
			count =>	$count,
			ratio =>	int(($count * 100000) /
				scalar(@sitewords))
		});
	}

	$sites = $schema->resultset('Linksto')->search({
		id_to =>	$obj->id
	});
	$authority = $sites->count;
	while (my $site = $sites->next)
	{
		$authority += ($site->from->authority / 10);
	}
	print('Final authority is ' . int($authority) . "\n");
	$authority = 32767 if ($authority > 32767);
	$obj->authority(int($authority));
	$obj->update();

	printf("Site indexed in %.02f seconds.\n", time() - $start);

	return 1;
}

my $ua = new LWP::UserAgent;
my $cj = HTTP::Cookies->new(
	file =>		"$ENV{HOME}/.searchengine-cookies.txt",
	ignore_discard => 1
);
$ua->timeout(10);
$ua->cookie_jar($cj);
$ua->show_progress(1);

foreach ($schema->resultset('Credential')->search({
	realm =>	\' IS NOT NULL'
}))
{
	my $uri = URI->new($_->url)->canonical;

	$ua->credentials($uri->host . ':' . $uri->port, $_->realm, $_->userid, $_->password) if (defined($_->realm));
}

foreach ($schema->resultset('Credential')->search({
	realm =>	\' IS NULL'
}))
{
	my $uri = URI->new($_->url)->canonical;

	# Gather some cookies
	if (defined($_->userparm) && defined($_->passparm))
	{
		$ua->post($uri->as_string,
			$_->userparm =>	$_->userid,
			$_->passparm =>	$_->password
		);
	}
}

$cj->save();

while (1)
{
	my $site = $schema->resultset('Website')->search({
		lastindex =>	undef,
		failed =>	0,
		url =>	[ -and =>
			{ -not_like =>'http://ftp.mozilla-japan.org/%'},
			{ -not_like =>'http://www.homedepot.com/%'},
			{ -not_like =>'http://www.homedepot.com:80/%'},
			{ -not_like =>'http://profile.microsoft.com/%'},
			{ -not_like =>'http://login.live.com/%'},
			{ -not_like =>'http://profile.microsoft.com/%'},
			{ -not_like =>'http://www.youtube.com/login%'},
			{ -not_like =>'http://www.youtube.com/signup%'},
			{ -not_like =>'http://alwayson.goingon.com/tools/%'},
			{ -not_like =>'https://accountservices.passport.net/%'},
			{ -not_like =>'https://profile.microsoft.com/%'},
			{ -not_like =>'https://login.live.com/%'},
			{ -not_like =>'https://secure.homedepot.com/%'},
			{ -not_like =>'https://secure.homedepot.com:443/%'},
			{ -not_like =>'%/cache/cache/cache/%'} ],
	}, {
		order_by =>	[qw(id)],
		rows =>	1
	})->next;
	unless (defined($site))
	{
		$site = $schema->resultset('Website')->search({
			url =>	[ -and =>
				{ -not_like =>'http://ftp.mozilla-japan.org/%'},
				{ -not_like =>'http://www.homedepot.com/%'},
				{ -not_like =>'http://www.homedepot.com:80/%'},
				{ -not_like =>'http://profile.microsoft.com/%'},
				{ -not_like =>'http://login.live.com/%'},
				{ -not_like =>'http://profile.microsoft.com/%'},
				{ -not_like =>'http://www.youtube.com/login%'},
				{ -not_like =>'http://www.youtube.com/signup%'},
				{ -not_like =>'http://alwayson.goingon.com/tools/%'},
				{ -not_like =>'https://accountservices.passport.net/%'},
				{ -not_like =>'https://profile.microsoft.com/%'},
				{ -not_like =>'https://login.live.com/%'},
				{ -not_like =>'https://secure.homedepot.com/%'},
				{ -not_like =>'https://secure.homedepot.com:443/%'},
				{ -not_like =>'%/cache/cache/cache/%'} ],
			failed =>	0
		}, {
			order_by =>	[qw(lastindex)],
			rows =>	1
		})->next;
	}
	index_site($ua, $site);

	# Activate this once we get to speed again
	# sleep(1);
}

exit(1);
