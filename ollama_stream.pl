#!/usr/bin/perl
# Streaming Ollama worker — reads JSON payload from file, streams response tokens to STDOUT
# Usage: ollama_stream.pl <url> <payload_file> <timeout>
use strict;
use warnings;
$| = 1;
binmode STDOUT, ':raw';

use HTTP::Tiny;
use JSON;
use Encode qw(encode_utf8);

my ($url, $payload_file, $timeout) = @ARGV;

open my $f, '<', $payload_file or die "Cannot open $payload_file: $!";
my $payload = do { local $/; <$f> };
close $f;
unlink $payload_file;

my $http = HTTP::Tiny->new(timeout => $timeout || 120);

# Streaming callback: Ollama sends one JSON object per line when stream=true
my $response = $http->request('POST', $url, {
    content => $payload,
    headers => { 'Content-Type' => 'application/json' },
    data_callback => sub {
        my ($chunk, $resp) = @_;
        # Each chunk may contain one or more newline-delimited JSON objects
        for my $line (split /\n/, $chunk) {
            next unless $line =~ /\S/;
            my $obj = eval { decode_json($line) };
            next unless $obj;
            if (defined $obj->{response} && length $obj->{response}) {
                print encode_utf8($obj->{response});
            }
        }
    },
});

unless ($response->{success} || $response->{status} == 599) {
    # 599 = internal timeout, but data_callback already got partial data
    print "Mein Gehirn antwortet nicht... ($response->{status})" unless $response->{success};
}
