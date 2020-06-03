package App::FfmpegUtils;

# AUTHORITY
# DATE
# DIST
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::ger;

use Perinci::Exporter;

our %SPEC;

$SPEC{':package'} = {
    v => 1.1,
    summary => 'Utilities related to ffmpeg',
};

our %arg0_files = (
    files => {
        'x.name.is_plural' => 1,
        'x.name.singular' => 'file',
        schema => ['array*' => of => 'filename*'],
        req => 1,
        pos => 0,
        slurpy => 1,
    },
);

our %argopt_ffmpeg_path = (
    ffmpeg_path => {
        schema => 'filename*',
    },
);

sub _nearest {
    sprintf("%d", $_[0]/$_[1]) * $_[1];
}

$SPEC{reencode_video} = {
    v => 1.1,
    summary => 'Re-encode video (using ffmpeg and H.264 codec)',
    description => <<'_',

This utility runs ffmpeg to re-encode your video files. Usually used to reduce
the file size (and optionally video width/height) so they are smaller, while
minimizing quality loss.

The default settings are:

    -v:c libx264
    -preset veryslow (to get the best compression rate, but with the slowest encoding time)
    -crf 28 (0-51, subjectively sane is 18-28, 18 ~ visually lossless, 28 ~ visually acceptable)

when a downsizing is requested (using the `--downsize-to` option), the `-vf
scale` option is used and this utility calculate a valid size for ffmpeg.

Audio streams are copied, not re-encoded.

Output filenames are:

    ORIGINAL_NAME.crf28.mp4

or (if downsizing is done):

    ORIGINAL_NAME.480p-crf28.mp4

_
    args => {
        %arg0_files,
        %argopt_ffmpeg_path,
        crf => {
            schema => ['int*', between=>[0,51]],
        },
        downsize_to => {
            schema => ['str*', in=>['480p', '720p', '1080p']],
        },
    },
    features => {
        dry_run => 1,
    },
};
sub reencode_video {
    require File::Which;
    require IPC::System::Options;
    require Media::Info;

    my %args = @_;

    my $ffmpeg_path = $args{ffmpeg_path} // File::Which::which("ffmpeg");
    my $downsize_to = $args{downsize_to};

    unless ($args{-dry_run}) {
        return [400, "Cannot find ffmpeg in path"] unless defined $ffmpeg_path;
        return [400, "ffmpeg path $ffmpeg_path is not executable"] unless -f $ffmpeg_path;
    }

    for my $file (@{$args{files}}) {
        log_info "Processing file %s ...", $file;

        unless (-f $file) {
            log_error "No such file %s, skipped", $file;
            next;
        }

        my $res = Media::Info::get_media_info(media => $file);
        unless ($res->[0] == 200) {
            log_error "Can't get media information fod %s: %s - %s, skipped",
                $file, $res->[0], $res->[1];
            next;
        }
        my $video_info = $res->[2];

        my $crf = $args{crf} // 28;
        my @ffmpeg_args = (
            "-i", $file,
        );
      DOWNSIZE: {
            last unless $downsize_to;
            my $ratio;
            if ($downsize_to eq '480p') {
                last unless $video_info->{video_shortest_side} > 480;
                $ratio = $video_info->{video_shortest_side} / 480;
            } elsif ($downsize_to eq '720p') {
                last unless $video_info->{video_shortest_side} > 720;
                $ratio = $video_info->{video_shortest_side} / 720;
            } elsif ($downsize_to eq '1080p') {
                last unless $video_info->{video_shortest_side} > 1080;
                $ratio = $video_info->{video_shortest_side} / 1080;
            } else {
                die "Invalid downsize_to value '$downsize_to'";
            }

            push @ffmpeg_args, "-vf", sprintf(
                "scale=%d:%d",
                _nearest($video_info->{video_width} / $ratio, 2),  # make sure divisible by 2 (optimum is divisible by 16, then 8, then 4)
                _nearest($video_info->{video_height} / $ratio, 2),
            );
        } # DOWNSIZE

        my $output_file = $file;
        my $ext = $downsize_to ? ".$downsize_to-crf$crf.mp4" : ".crf$crf.mp4";
        $output_file =~ s/(\.\w{3,4})?\z/($1 eq ".mp4" ? "" : $1) . $ext/e;

        push @ffmpeg_args, (
            "-c:v", "libx264",
            "-crf", $crf,
            "-preset", "veryslow",
            "-c:a", "copy",
            $output_file,
        );

        if ($args{-dry_run}) {
            log_info "[DRY-RUN] Running $ffmpeg_path with args %s ...", \@ffmpeg_args;
            next;
        }

        IPC::System::Options::system(
            {log=>1},
            $ffmpeg_path, @ffmpeg_args,
        );
        if ($?) {
            my ($exit_code, $signal, $core_dump) = ($? < 0 ? $? : $? >> 8, $? & 127, $? & 128);
            log_error "ffmpeg for $file failed: exit_code=$exit_code, signal=$signal, core_dump=$core_dump";
        }
    }

    [200];
}

1;
# ABSTRACT:
