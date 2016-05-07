package App::Fasops::Common;
use strict;
use warnings;
use autodie;

use 5.010000;

use AlignDB::IntSpan;
use Carp;
use IO::Zlib;
use IPC::Cmd;
use List::MoreUtils;
use Path::Tiny;
use Tie::IxHash;
use YAML::Syck;

use App::RL::Common;

sub read_replaces {
    my $file = shift;

    tie my %replace, "Tie::IxHash";
    my @lines = path($file)->lines( { chomp => 1 } );
    for (@lines) {
        my @fields = split /\t/;
        if ( @fields >= 1 ) {
            my $ori = shift @fields;
            $replace{$ori} = [@fields];
        }
    }

    return \%replace;
}

sub parse_block {
    my $block = shift;

    my @lines = grep {/\S/} split /\n/, $block;
    Carp::croak "Numbers of headers not equal to seqs\n" if @lines % 2;

    tie my %info_of, "Tie::IxHash";
    while (@lines) {
        my $header = shift @lines;
        $header =~ s/^\>//;
        chomp $header;

        my $seq = shift @lines;
        chomp $seq;

        my $info_ref = App::RL::Common::decode_header($header);
        $info_ref->{seq} = $seq;
        if ( defined $info_ref->{name} ) {
            $info_of{ $info_ref->{name} } = $info_ref;
        }
        else {
            my $ess_header = App::RL::Common::encode_header( $info_ref, 1 );
            $info_of{$ess_header} = $info_ref;
        }
    }

    return \%info_of;
}

sub parse_block_header {
    my $block = shift;

    my @lines = grep {/\S/} split /\n/, $block;
    Carp::croak "Numbers of headers not equal to seqs\n" if @lines % 2;

    tie my %info_of, "Tie::IxHash";
    while (@lines) {
        my $header = shift @lines;
        $header =~ s/^\>//;
        chomp $header;

        my $seq = shift @lines;
        chomp $seq;

        my $info_ref = App::RL::Common::decode_header($header);
        my $ess_header = App::RL::Common::encode_header( $info_ref, 1 );
        $info_ref->{seq} = $seq;
        $info_of{$ess_header} = $info_ref;
    }

    return \%info_of;
}

sub parse_axt_block {
    my $block     = shift;
    my $length_of = shift;

    my @lines = grep {/\S/} split /\n/, $block;
    Carp::croak "A block of axt should contain three lines\n" if @lines != 3;

    my ($align_serial, $first_chr,  $first_start,  $first_end, $second_chr,
        $second_start, $second_end, $query_strand, $align_score,
    ) = split /\s+/, $lines[0];

    if ( $query_strand eq "-" ) {
        if ( defined $length_of and ref $length_of eq "HASH" ) {
            if ( exists $length_of->{$second_chr} ) {
                $second_start = $length_of->{$second_chr} - $second_start + 1;
                $second_end   = $length_of->{$second_chr} - $second_end + 1;
                ( $second_start, $second_end ) = ( $second_end, $second_start );
            }
        }
    }

    my %info_of = (
        target => {
            name       => "target",
            chr_name   => $first_chr,
            chr_start  => $first_start,
            chr_end    => $first_end,
            chr_strand => "+",
            seq        => $lines[1],
        },
        query => {
            name       => "query",
            chr_name   => $second_chr,
            chr_start  => $second_start,
            chr_end    => $second_end,
            chr_strand => $query_strand,
            seq        => $lines[2],
        },
    );

    return \%info_of;
}

sub parse_maf_block {
    my $block = shift;

    my @lines = grep {/\S/} split /\n/, $block;
    Carp::croak "A block of maf should contain s lines\n" unless @lines > 0;

    tie my %info_of, "Tie::IxHash";

    for my $sline (@lines) {
        my ( $s, $src, $start, $size, $strand, $srcsize, $text ) = split /\s+/, $sline;

        my ( $species, $chr_name ) = split /\./, $src;
        $chr_name = $species if !defined $chr_name;

        # adjust coordinates to be one-based inclusive
        $start = $start + 1;

        $info_of{$species} = {
            name       => $species,
            chr_name   => $chr_name,
            chr_start  => $start,
            chr_end    => $start + $size - 1,
            chr_strand => $strand,
            seq        => $text,
        };
    }

    return \%info_of;
}

sub revcom {
    my $seq = shift;

    $seq =~ tr/ACGTMRWSYKVHDBNacgtmrwsykvhdbn-/TGCAKYWSRMBDHVNtgcakyswrmbdhvn-/;
    my $seq_rc = reverse $seq;

    return $seq_rc;
}

sub seq_length {
    my $seq = shift;

    my $gaps = $seq =~ tr/-/-/;

    return length($seq) - $gaps;
}

sub indel_intspan {
    my $seq = shift;

    my $intspan = AlignDB::IntSpan->new;
    my $length  = length($seq);

    my $offset = 0;
    my $start  = 0;
    my $end    = 0;
    for my $pos ( 1 .. $length ) {
        my $base = substr( $seq, $pos - 1, 1 );
        if ( $base eq '-' ) {
            if ( $offset == 0 ) {
                $start = $pos;
            }
            $offset++;
        }
        else {
            if ( $offset != 0 ) {
                $end = $pos - 1;
                $intspan->add_pair( $start, $end );
            }
            $offset = 0;
        }
    }
    if ( $offset != 0 ) {
        $end = $length;
        $intspan->add_pair( $start, $end );
    }

    return $intspan;
}

sub align_seqs {
    my $seq_refs = shift;
    my $aln_prog = shift;

    # get executable
    my $bin;

    if ( !defined $aln_prog or $aln_prog =~ /clus/i ) {
        $aln_prog = 'clustalw';
        for my $e (qw{clustalw clustal-w clustalw2}) {
            if ( IPC::Cmd::can_run($e) ) {
                $bin = $e;
                last;
            }
        }
    }
    elsif ( $aln_prog =~ /musc/i ) {
        $aln_prog = 'muscle';
        for my $e (qw{muscle}) {
            if ( IPC::Cmd::can_run($e) ) {
                $bin = $e;
                last;
            }
        }
    }
    elsif ( $aln_prog =~ /maff/i ) {
        $aln_prog = 'mafft';
        for my $e (qw{mafft}) {
            if ( IPC::Cmd::can_run($e) ) {
                $bin = $e;
                last;
            }
        }
    }

    if ( !defined $bin ) {
        confess "Could not find the executable for $aln_prog\n";
    }

    # temp in and out
    my $temp_in  = Path::Tiny->tempfile("seq_in_XXXXXXXX");
    my $temp_out = Path::Tiny->tempfile("seq_out_XXXXXXXX");

    # msa may change the order of sequences
    my @indexes = 0 .. scalar( @{$seq_refs} - 1 );
    {
        my $fh = $temp_in->openw;
        for my $i (@indexes) {
            printf {$fh} ">seq_%d\n", $i;
            printf {$fh} "%s\n",      $seq_refs->[$i];
        }
        close $fh;
    }

    my @args;
    if ( $aln_prog eq "clustalw" ) {
        push @args, "-align -type=dna -output=fasta -outorder=input -quiet";
        push @args, "-infile=" . $temp_in->absolute->stringify;
        push @args, "-outfile=" . $temp_out->absolute->stringify;
    }
    elsif ( $aln_prog eq "muscle" ) {
        push @args, "-quiet";
        push @args, "-in " . $temp_in->absolute->stringify;
        push @args, "-out " . $temp_out->absolute->stringify;
    }
    elsif ( $aln_prog eq "mafft" ) {
        push @args, "--quiet";
        push @args, "--auto";
        push @args, $temp_in->absolute->stringify;
        push @args, "> " . $temp_out->absolute->stringify;
    }

    my $cmd_line = join " ", ( $bin, @args );
    my $ok = IPC::Cmd::run( command => $cmd_line );

    if ( !$ok ) {
        Carp::confess("$aln_prog call failed\n");
    }

    my @aligned;
    my $seq_of = read_fasta( $temp_out->absolute->stringify );
    for my $i (@indexes) {
        push @aligned, $seq_of->{ "seq_" . $i };
    }

    # delete .dnd files created by clustalw
    #printf STDERR "%s\n", $temp_in->absolute->stringify;
    if ( $aln_prog eq "clustalw" ) {
        my $dnd = $temp_in->absolute->stringify . ".dnd";
        path($dnd)->remove;
    }

    undef $temp_in;
    undef $temp_out;

    return \@aligned;
}

# read normal fasta files
sub read_fasta {
    my $filename = shift;

    tie my %seq_of, "Tie::IxHash";
    my @lines = path($filename)->lines;

    my $cur_name;
    for my $line (@lines) {
        if ( $line =~ /^\>\S+/ ) {
            $line =~ s/\>//;
            chomp $line;
            $cur_name = $line;
            $seq_of{$cur_name} = '';
        }
        elsif ( $line =~ /^[\w-]+/ ) {
            chomp $line;
            $seq_of{$cur_name} .= $line;
        }
        else {    # Blank line, do nothing
        }
    }

    return \%seq_of;
}

sub mean {
    @_ = grep { defined $_ } @_;
    return 0 unless @_;
    return $_[0] unless @_ > 1;
    return List::Util::sum(@_) / scalar(@_);
}

sub calc_gc_ratio {
    my $seq_refs = shift;

    my $seq_count = scalar @{$seq_refs};

    my @ratios;
    for my $i ( 0 .. $seq_count - 1 ) {

        # Count all four bases
        my $a_count = $seq_refs->[$i] =~ tr/Aa/Aa/;
        my $g_count = $seq_refs->[$i] =~ tr/Gg/Gg/;
        my $c_count = $seq_refs->[$i] =~ tr/Cc/Cc/;
        my $t_count = $seq_refs->[$i] =~ tr/Tt/Tt/;

        my $four_count = $a_count + $g_count + $c_count + $t_count;
        my $gc_count   = $g_count + $c_count;

        if ( $four_count == 0 ) {
            next;
        }
        else {
            my $gc_ratio = $gc_count / $four_count;
            push @ratios, $gc_ratio;
        }
    }

    return mean(@ratios);
}

1;
