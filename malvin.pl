#!/usr/bin/perl
#
# this code is mainly written by claude opus 4.6
# the project is a test for the agent system to see
# code-quality in perl and python
#
# (c) 2006-2026 by braindead ges.m.b.e.
# created by xir - www.anares.ai - www.strg.at

 
use strict;
use warnings;
use utf8;
use Encode qw(decode_utf8 encode_utf8);
use POE;
use POE::Component::IRC;
use POE::Wheel::Run;
use POE::Filter::Stream;
use JSON;
use YAML::Tiny;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use Time::HiRes qw(gettimeofday tv_interval);

binmode STDOUT, ':utf8';
binmode STDERR, ':utf8';

$| = 1;  # Autoflush STDOUT

# Load configuration
my $config_file = $ARGV[0] || 'malvin.conf';
my $yaml = YAML::Tiny->read($config_file)
    or die "Cannot read $config_file: " . YAML::Tiny->errstr . "\n";
my $config = $yaml->[0];

my $irc_conf    = $config->{irc};
my $ollama_conf = $config->{ollama};
my $bot_conf    = $config->{bot};
my $system_prompt = $config->{system_prompt};

# Path to the streaming worker script
my $worker_script = "$Bin/ollama_stream.pl";

# Rolling context buffer: { channel => [ "nick: message", ... ] }
my %context;

# Track pending requests per channel to avoid flooding
my %pending;

# Create IRC component
my $irc = POE::Component::IRC->spawn(
    nick    => $irc_conf->{nickname},
    ircname => $irc_conf->{ircname} || $irc_conf->{nickname},
    server  => $irc_conf->{server},
    port    => $irc_conf->{port} || 6667,
) or die "Failed to create IRC component: $!\n";

# Create main POE session
POE::Session->create(
    package_states => [
        main => [qw(
            _start
            irc_001
            irc_public
            irc_msg
            _child_stdout
            _child_stderr
            _child_close
            _child_error
            _sig_child
            _warmup_done
            _default
        )],
    ],
    heap => {
        irc    => $irc,
        wheels  => {},
    },
);

POE::Kernel->run();
exit 0;

# --- Event handlers ---

sub _start {
    my ($kernel, $heap) = @_[KERNEL, HEAP];
    $kernel->alias_set('malvin_bot');

    my $irc_session = $heap->{irc}->session_id();
    $kernel->post($irc_session => register => 'all');
    $kernel->post($irc_session => connect  => {});
    print "Connecting to $irc_conf->{server}:$irc_conf->{port}...\n";
}

sub irc_001 {
    my ($kernel, $heap) = @_[KERNEL, HEAP];
    print "Connected. Joining channels...\n";
    for my $chan (@{ $irc_conf->{channels} }) {
        $heap->{irc}->yield(join => $chan);
        print "  Joining $chan\n";
    }

    # Warmup: pre-load the model into Ollama memory
    _warmup_model($kernel, $heap);
}

sub _warmup_model {
    my ($kernel, $heap) = @_;
    print "Warming up model $ollama_conf->{model}...\n";

    my $payload = encode_json({
        model     => $ollama_conf->{model},
        prompt    => "hi",
        system    => "Reply with one word.",
        stream    => JSON::false,
        keep_alive => "30m",
    });

    my ($fh, $tmpfile) = tempfile('/tmp/malvin_warmup_XXXX', SUFFIX => '.json', UNLINK => 0);
    print $fh $payload;
    close $fh;

    my $wheel = POE::Wheel::Run->new(
        Program     => [ $^X, '-I', "$ENV{HOME}/perl5/lib/perl5",
                         $worker_script,
                         "$ollama_conf->{url}/api/generate", $tmpfile,
                         $ollama_conf->{timeout} || 120 ],
        StdoutFilter => POE::Filter::Stream->new(),
        StdoutEvent  => '_warmup_done',
        StderrEvent  => '_child_stderr',
        CloseEvent   => '_warmup_done',
        ErrorEvent   => '_child_error',
    );

    $heap->{warmup_wheel} = $wheel;
    $kernel->sig_child($wheel->PID, '_sig_child');
}

sub _warmup_done {
    my ($heap, $output) = @_[HEAP, ARG0];
    if (defined $output && $output =~ /\S/) {
        print "Model warmup complete.\n";
    }
    delete $heap->{warmup_wheel};
}

sub irc_public {
    my ($kernel, $heap, $who, $where, $msg) = @_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    my $nick    = (split /!/, $who)[0];
    my $channel = $where->[0];

    # Store message in rolling context
    push @{ $context{$channel} }, "$nick: $msg";
    my $max = $bot_conf->{context_lines} || 20;
    if (@{ $context{$channel} } > $max) {
        splice @{ $context{$channel} }, 0, @{ $context{$channel} } - $max;
    }

    # Handle commands
    if ($msg =~ /^!help\s*$/i) {
        $heap->{irc}->yield(privmsg => $channel,
            "Befehle: !help - diese Hilfe | !status - Bot-Status | "
            . "Oder sag einfach meinen Namen... seufz.");
        return;
    }
    if ($msg =~ /^!status\s*$/i) {
        my $ctx_count = scalar @{ $context{$channel} || [] };
        $heap->{irc}->yield(privmsg => $channel,
            "Ich lebe noch... leider. Kontext: $ctx_count Zeilen. "
            . "Modell: $ollama_conf->{model}.");
        return;
    }

    # Check if bot name is mentioned (case-insensitive)
    my $trigger = quotemeta($bot_conf->{trigger_name} || 'malvin');
    return unless $msg =~ /$trigger/i;

    # Don't queue multiple requests per channel
    if ($pending{$channel}) {
        return;
    }
    $pending{$channel} = 1;
    my $t0 = [gettimeofday];
    print "$channel: <$nick> $msg\n";
    printf "  step trigger / needed time %.4fs\n", tv_interval($t0);

    # Build conversation context for the LLM
    my $context_text = join("\n", @{ $context{$channel} || [] });

    my $prompt = "Aktueller IRC-Kanal: $channel\n"
               . "Bisheriger Chatverlauf:\n$context_text\n\n"
               . "Antworte auf die letzte Nachricht von $nick.";

    # Build the Ollama request payload — streaming enabled, keep model loaded
    my $payload = encode_json({
        model      => $ollama_conf->{model},
        prompt     => $prompt,
        system     => $system_prompt,
        stream     => JSON::true,
        keep_alive => "30m",
        options    => {
            num_predict => 150,
            num_ctx     => 2048,
        },
    });
    printf "  step build_payload / needed time %.4fs\n", tv_interval($t0);

    my ($fh, $tmpfile) = tempfile('/tmp/malvin_req_XXXX', SUFFIX => '.json', UNLINK => 0);
    print $fh $payload;
    close $fh;
    printf "  step write_tmpfile / needed time %.4fs\n", tv_interval($t0);

    # Fork the streaming worker process
    my $wheel = POE::Wheel::Run->new(
        Program     => [ $^X, '-I', "$ENV{HOME}/perl5/lib/perl5",
                         $worker_script,
                         "$ollama_conf->{url}/api/generate", $tmpfile,
                         $ollama_conf->{timeout} || 120 ],
        StdoutFilter => POE::Filter::Stream->new(),
        StdoutEvent  => '_child_stdout',
        StderrEvent  => '_child_stderr',
        CloseEvent   => '_child_close',
        ErrorEvent   => '_child_error',
    );
    printf "  step fork_worker / needed time %.4fs\n", tv_interval($t0);

    my $wid = $wheel->ID;
    $heap->{wheels}{$wid} = {
        wheel   => $wheel,
        channel => $channel,
        buffer  => '',      # accumulates streamed tokens
        sent    => 0,       # messages already sent to IRC
        t_start => $t0,     # request start time
    };

    $kernel->sig_child($wheel->PID, '_sig_child');
}

sub irc_msg {
    my ($kernel, $heap, $who, $msg) = @_[KERNEL, HEAP, ARG0, ARG2];
    my $nick = (split /!/, $who)[0];
    $heap->{irc}->yield(privmsg => $nick,
        "Ich bin nur ein trauriger Bot... schreib mir im Channel.");
}

sub _child_stdout {
    my ($kernel, $heap, $output, $wid) = @_[KERNEL, HEAP, ARG0, ARG1];
    my $info = $heap->{wheels}{$wid} or return;

    if (length($info->{buffer}) == 0 && length($output) > 0) {
        printf "  step first_token / needed time %.4fs\n", tv_interval($info->{t_start});
    }

    $info->{buffer} .= $output;

    # Try to send complete sentences while streaming
    _flush_sentences($heap, $wid, 0);
}

sub _child_stderr {
    my ($heap, $output, $wid) = @_[HEAP, ARG0, ARG1];
    print STDERR "Ollama child STDERR: $output\n";
}

sub _child_close {
    my ($kernel, $heap, $wid) = @_[KERNEL, HEAP, ARG0];

    return unless defined $wid && exists $heap->{wheels}{$wid};

    my $t_start = $heap->{wheels}{$wid}{t_start};
    printf "  step stream_complete / needed time %.4fs\n", tv_interval($t_start);

    # Flush any remaining text
    _flush_sentences($heap, $wid, 1);

    my $info = delete $heap->{wheels}{$wid};
    delete $pending{$info->{channel}};
    printf "  step done / needed time %.4fs\n", tv_interval($t_start);

    # If nothing was sent at all, send a fallback
    if ($info->{sent} == 0) {
        my $remaining = decode_utf8($info->{buffer});
        $remaining =~ s/\s+/ /g;
        $remaining =~ s/^\s+|\s+$//g;
        if (length $remaining) {
            $heap->{irc}->yield(privmsg => $info->{channel}, encode_utf8($remaining));
        } else {
            $heap->{irc}->yield(privmsg => $info->{channel},
                "... ich hab gerade keine Worte.");
        }
    }
}

sub _child_error {
    my ($heap, $operation, $errnum, $errstr, $wid) = @_[HEAP, ARG0, ARG1, ARG2, ARG3];
    return if $operation eq 'read' && $errnum == 0;  # normal EOF
    print STDERR "Wheel $wid error: $operation ($errnum) $errstr\n";
}

sub _sig_child {
    return;
}

sub _default {
    return 0;
}

# --- Helper functions ---

# Flush complete sentences from the stream buffer to IRC
sub _flush_sentences {
    my ($heap, $wid, $final) = @_;
    my $info = $heap->{wheels}{$wid} or return;

    my $max_len = $bot_conf->{max_response_length} || 400;
    my $channel = $info->{channel};

    # Decode and clean up whitespace
    my $text = decode_utf8($info->{buffer});
    $text =~ s/\n/ /g;
    $text =~ s/  +/ /g;

    while (length $text) {
        my $send;

        if (length($text) >= $max_len) {
            # Force-split at max_len on a sentence or word boundary
            my $chunk = substr($text, 0, $max_len);
            if ($chunk =~ /^(.+[.!?])\s/) {
                $send = $1;
            } else {
                my $last_space = rindex($chunk, ' ');
                $send = $last_space > 0 ? substr($chunk, 0, $last_space) : $chunk;
            }
        } elsif ($final) {
            # End of stream — send whatever remains
            $text =~ s/^\s+|\s+$//g;
            $send = $text if length $text;
            $text = '';
        } elsif ($text =~ /^(.+[.!?])\s/) {
            # Complete sentence available — send it now
            $send = $1;
        } else {
            # No complete sentence yet, wait for more tokens
            last;
        }

        last unless defined $send;
        $send =~ s/^\s+|\s+$//g;
        unless (length $send) {
            # Edge case: only whitespace matched, trim and retry
            $text =~ s/^\s+//;
            next;
        }

        if ($info->{sent} == 0) {
            printf "  step first_irc_send / needed time %.4fs\n", tv_interval($info->{t_start});
        }
        $heap->{irc}->yield(privmsg => $channel, encode_utf8($send));
        $info->{sent}++;

        # Remove sent text from buffer
        my $pos = index($text, $send);
        if ($pos >= 0) {
            $text = substr($text, $pos + length($send));
            $text =~ s/^\s+//;
        } else {
            $text = '';
        }
    }

    # Store remaining text back in buffer
    $info->{buffer} = encode_utf8($text);
}
