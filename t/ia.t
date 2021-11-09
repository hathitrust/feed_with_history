use FindBin;
use lib "$FindBin::Bin/lib";

use Test::Spec;
use HTFeed::Test::Support qw(load_db_fixtures);
use HTFeed::Test::SpecSupport qw(mock_zephir);
use HTFeed::Config qw(set_config);


context "with volume & temporary ingest/preingest/zipfile dirs" => sub {
  my $volume;
  my $objid;
  my $pt_objid;

  my $tmpdir;

  my $tmpdirs;

  before all => sub {
    load_db_fixtures;
    $tmpdirs = HTFeed::Test::TempDirs->new();
    $objid = 'ark:/13960/t7kq2zj36';
    $pt_objid = 'ark+=13960=t7kq2zj36';
  };

  before each => sub {
    $tmpdirs->setup_example;
    set_config($tmpdirs->test_home . "/fixtures",'staging','download');

    $volume = HTFeed::Volume->new(namespace => 'test',
      objid => $objid,
      packagetype => 'ia');
    $volume->{ia_id} = 'ark+=13960=t7kq2zj36';
  };

  after each => sub {
    $tmpdirs->cleanup_example;
  };

  after all => sub {
    $tmpdirs->cleanup;
  };

  describe "HTFeed::PackageType::IA::VerifyManifest" => sub {
    my $stage;

    before each => sub {
      HTFeed::PackageType::IA::Unpack->new(volume => $volume)->run();
      $stage = HTFeed::PackageType::IA::VerifyManifest->new(volume => $volume);
    };

    it "succeeds" => sub {
      $stage->run();
      ok($stage->succeeded());
    };

    after each => sub {
      $stage->clean();
    };
  };

  describe "HTFeed::PackageType::IA::Unpack" => sub {
    my $stage;

    before each => sub {
      $stage = HTFeed::PackageType::IA::Unpack->new(volume => $volume);
    };

    it "succeeds" => sub {
      $stage->run();
      ok($stage->succeeded());
    };

    it "extracts the zip" => sub {
      $stage->run();

      my $ia_id = $volume->get_ia_id();
      ok(-e "$tmpdirs->{preingest}/$pt_objid/${ia_id}_0001.jp2");
    };

    after each => sub {
      $stage->clean();
    };
  };

  describe "HTFeed::PackageType::IA::SourceMETS" => sub {
    my $stage;
    my $mets_xml;

    before each => sub {
      HTFeed::PackageType::IA::VerifyManifest->new(volume => $volume)->run();
      HTFeed::PackageType::IA::Unpack->new(volume => $volume)->run();
      HTFeed::PackageType::IA::DeleteCheck->new(volume => $volume)->run();
      HTFeed::PackageType::IA::OCRSplit->new(volume => $volume)->run();
      HTFeed::PackageType::IA::ImageRemediate->new(volume => $volume)->run();
      $stage = HTFeed::PackageType::IA::SourceMETS->new(volume => $volume);
      mock_zephir();
      $mets_xml = "$tmpdirs->{ingest}/$pt_objid/IA_$pt_objid.xml"
    };

    it "succeeds" => sub {
      $stage->run();
      ok($stage->succeeded());
    };

    it "generates the METS xml" => sub {
      $stage->run();
      ok(-e $mets_xml);
    };

    context "with a mets xml" => sub {

      before each => sub {
        $stage->run;
      };

      it "writes scanningOrder, readingOrder, and coverTag" => sub {
        my $xc = $volume->_parse_xpc($mets_xml);
        ok($xc->findnodes('/METS:mets/METS:dmdSec/METS:mdWrap/METS:xmlData/gbs:scanningOrder')->size() == 1);
        is($xc->findvalue('/METS:mets/METS:dmdSec/METS:mdWrap/METS:xmlData/gbs:scanningOrder'), 'right-to-left');
        ok($xc->findnodes('/METS:mets/METS:dmdSec/METS:mdWrap/METS:xmlData/gbs:readingOrder')->size() == 1);
        is($xc->findvalue('/METS:mets/METS:dmdSec/METS:mdWrap/METS:xmlData/gbs:readingOrder'), 'right-to-left');
        ok($xc->findnodes('/METS:mets/METS:dmdSec/METS:mdWrap/METS:xmlData/gbs:coverTag')->size() == 1);
        is($xc->findvalue('/METS:mets/METS:dmdSec/METS:mdWrap/METS:xmlData/gbs:coverTag'), 'follows-reading-order');
      };
    };
  };
};

runtests unless caller;
