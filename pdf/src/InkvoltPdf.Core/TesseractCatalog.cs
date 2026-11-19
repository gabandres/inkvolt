// Written by pdf/tools/tesseract-pin/pin.py; run it again to pin another release rather than editing this file.

namespace InkvoltPdf.Core;

public static partial class TesseractCatalog
{
    /// <summary>Tesseract's version as its Windows installer names it.</summary>
    public const string Version = "5.5.3.20260724";

    /// <summary>The installer: tesseract-ocr/tesseract's GitHub release, built and signed by UB Mannheim.</summary>
    public static readonly Uri InstallerUrl = new("https://github.com/tesseract-ocr/tesseract/releases/download/5.5.3/tesseract-ocr-w64-setup-5.5.3.20260724.exe");

    public const long InstallerSize = 26573224;

    public const string InstallerSha256 = "bee9e3434bd94fd65387d9be28cd467a41f61b1275383b55b0f59a1331270ae4";

    /// <summary>Where the installer's solid LZMA stream starts (after NSIS's first header), its properties byte and dictionary size.</summary>
    public const long StreamOffset = 130076;

    public const byte StreamProperties = 93;

    public const uint StreamDictionary = 33554432;

    /// <summary>tesseract.exe, the DLLs it loads, and the licence: each one's place in the decompressed stream, size and SHA-256.</summary>
    public static readonly EngineFile[] EngineFiles =
    [
        new("tesseract.exe", 733066, 1867784, "c66f0f12ed76f6aa455dac97684bbc86756d6a732380bee09122454cfda3f420"),
        new("libtesseract-5.dll", 2600854, 3501048, "54d54528b453ce3a5ba79487687f8df43e7b194b9ea97beba74200453fe1fb46"),
        new("libLerc.dll", 6101906, 804265, "6887fb5aeabf382a835a4cb693025e8d48d9c90e82ca4eae5d2d8ffb70c6ca9a"),
        new("libarchive-13.dll", 6906175, 972210, "ddabddfdc98e1e1342ce4a7069fb4004de6c870d7bc9f4e95ef243dd18468e97"),
        new("libb2-1.dll", 7878389, 34653, "77bab532b5421d6cdddb96c3ae9a4bde144eb481ccaf243336c9f8c690a50987"),
        new("libbrotlicommon.dll", 7913046, 143429, "ca7bc06ead80259971badf2cd0bfc688db9154dad65f139f49a38b4be9976f97"),
        new("libbrotlidec.dll", 8056479, 62461, "a142dc6cfa77cb907028aa9426f486f3d8de37855e8db2ae2894147908121881"),
        new("libbz2-1.dll", 8118944, 100964, "b79cd3a7102e359ef6324e98966a67939e58ec2b651ae2847cae84a4dfa453f7"),
        new("libcurl-4.dll", 9467080, 1226963, "3d302f9690e810fdfd950254e2f0663d0ff768737f350c602a4ed3a06e9b6b2b"),
        new("libdeflate.dll", 10729084, 99228, "3f3fc3a73bc3623dc93b37bb321c484d3731d93006fd01c0495d15711826eb44"),
        new("libexpat-1.dll", 10828316, 237603, "92ae866c6c58dd2d8366aa0e6230ba8d434d5306e8d8c3a08b7e61750fc16153"),
        new("libgcc_s_seh-1.dll", 12556804, 954773, "172cfdc9d83703ec0a0ca2cee08f6cf2a166b801717ee51a56b3a63b36bc2f83"),
        new("libgif-7.dll", 13511581, 45777, "5b3d837ccaab84683dd93fbaddf2d98e1a9f90e0ddb8ea73dc70157adb4d26f1"),
        new("libiconv-2.dll", 19134529, 1143148, "7a282a854e01be726c6cccfe46f548c716aa45b3014818468253aaa4efbcd067"),
        new("libidn2-0.dll", 58584832, 247081, "9880b52651a0247640a2531d777380f7c35fac7efa7e3979b265ddcb78db8642"),
        new("libintl-8.dll", 58831917, 298731, "0537c3dd2378218508ebe3cc416d72a99ee2d24ae1c5525e23458f32544ef861"),
        new("libjbig-0.dll", 59130652, 62083, "275a827ba6839d47cfdbe059db1b1b403a92ff26e2b76a29362915487868bef2"),
        new("libjpeg-8.dll", 59192739, 967968, "b564d34adaca83e73af0e2231719dd0198ea6cd074c64b2ba85bfd7182f27db7"),
        new("libleptonica-6.dll", 60160711, 2850600, "1869b44e3d46fd830620b042477e5d60a950779582f38f60291547efb27792f1"),
        new("liblz4.dll", 63011315, 158649, "35f917274bca8f19677ba66f1b3cc3c83568c3249fc43215fc16e76439c8e856"),
        new("liblzma-5.dll", 63169968, 191836, "dc9edb9bd83b0371fe68d96cb3e70cd17b7a5aba958326a18f8210cb812432e9"),
        new("libopenjp2-7.dll", 63361808, 519082, "123587086cb1a25d2a338fb9b7c1d6bda10bf9062625b4f08c6a92b3d9cafe47"),
        new("libpng16-16.dll", 66086407, 264269, "3737838ee8d6b893df7bdabf7439775371a57dce7e17ee6b35586023c64bd9ab"),
        new("libpsl-5.dll", 66350680, 105304, "b31fc70eda598a39b65fe2736d815518db0652d641346f75eac40c2a0499b058"),
        new("libsharpyuv-0.dll", 66455988, 53757, "ab0c9f61dc69b6bcdff1011e215f8d5fd6e5096aba9be3386ab87f217fbbeffe"),
        new("libssh2-1.dll", 66509749, 271318, "ee7fe3e749859334c99e9261689481dd879811122598d22585421f95d29fc7ae"),
        new("libstdc++-6.dll", 66781071, 26390974, "5fe5d4d8f6636eb6f2dc55be99dc5dc8a6c40db1abdf592e84480d1e6985abd0"),
        new("libtiff-6.dll", 93244347, 625178, "47fe69165bf8e211aaa84224f51f145dc894e330fe7ca167f7c99419e0c8c894"),
        new("libunistring-5.dll", 93869529, 2251328, "b91e2850d3668d4931056a8f4d35783b8ec3eea3735485108a936a072cd16071"),
        new("libwebp-7.dll", 96120861, 749724, "c6c21a10f8cfe13270832e64640b82709e1d87b956b5f15af435a6c25acd6bbf"),
        new("libwebpmux-3.dll", 96870589, 82858, "2c8a2e9d7901ec65330f31f9989c2a07ef0506e903b485fcd8b241a6bab9b88f"),
        new("libwinpthread-1.dll", 96953451, 65955, "6a661d5846d80a91394dbb9b2dab87ba3cc705eac80ad45fe73677bff70cd6d2"),
        new("libzstd.dll", 97019410, 1218273, "b95c223a9548a9ecf51377c962e0bc8f0c51eb0c6f67a296dbc885996f0dd40d"),
        new("zlib1.dll", 98237687, 128488, "93e9243a44c29200eeacaf9658efe2558581770e4b11ca4b500e18e424a6e3b5"),
        new("LICENSE", 99036135, 11358, "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"),
    ];

    /// <summary>The tessdata_fast commit the language data is taken from.</summary>
    public const string LanguageCommit = "87416418657359cb625c412a48b6e1d6d41c29bd";

    /// <summary>Tesseract's languages (code, BCP-47 tag, English name, size, SHA-256), by English name.</summary>
    public static readonly TesseractLanguage[] Languages =
    [
        new("afr", "af", "Afrikaans", 2652786, "126d480bfae95be2a911ed4916465e27bde75fea2da631e21b96762e5f239646"),
        new("sqi", "sq", "Albanian", 1874705, "1d89621d9afe8ddf35b403ecf8951edea52c3a960d241f287b1a7b2c5ba8daac"),
        new("amh", "am", "Amharic", 5470094, "3ec3311833a108e07d58a1152b00c0cf1848752e4f85769d46e8ca2b718a2ccc"),
        new("grc", "grc", "Ancient Greek", 2246328, "57b735557eeb67503803cf9f99786dd0b62417931352601952a0b1a23b6c4759"),
        new("ara", "ar", "Arabic", 1432056, "e3206d3dc87fd50c24a0fb9f01838615911d25168f4e64415244b67d2bb3e729"),
        new("hye", "hy", "Armenian", 3463717, "b701d0d95799a716143dedb0197504e56f27a1bb133d6607ff5778c6988cb67c"),
        new("asm", "as", "Assamese", 2045427, "299c7f6135ac72ca4820d4c39e3cf65b32b24127fc78c4938d11153adbb9fa77"),
        new("aze_cyrl", "az-Cyrl", "Azerbaijani (Cyrillic)", 1943672, "2e96ab67817819e14a3a2d6250261130457c8e78dde3077841ab391fe003551c"),
        new("aze", "az-Latn", "Azerbaijani (Latin)", 3524799, "a365310848aecb739f19369cb3831d4660fcd9345d798e91a3042455f9ccc9f0"),
        new("ben", "bn", "Bangla", 855841, "31163084c279aaebd376216f0c3d5c17ad4b5fee8db49dae79c20000b5de5964"),
        new("eus", "eu", "Basque", 5175921, "40e7418296c355d9fd9ca843d115c51e740089e576e887443e61704823cd6624"),
        new("bel", "be", "Belarusian", 3692098, "9c6668a0b202f3dcfe074b64620d108e1902ca7498a40b5a11b4a3da6112d58f"),
        new("bos", "bs", "Bosnian", 2498242, "6cc8cc87cf1afbfa6a41febb725dbadb14bed96a46685906440a6eb8a7892f04"),
        new("bre", "br", "Breton", 6335007, "db8b31f76b986d63b82dfff9e84e252bf5f7dc53d9128167aaab18b3ec96dd49"),
        new("bul", "bg", "Bulgarian", 1675212, "aebc9b0fcc8cfaf8a9f38a02bb7b85052bd850744696a2c11cf0081820e5b21e"),
        new("mya", "my", "Burmese", 4640561, "02aa6c25cfe9e583fa7b5d4131eac948f962308983f0f397df077dea58212b03"),
        new("cat", "ca", "Catalan", 1146012, "250db73cd5b380d2798581295dc12f20d0828cdb335a65d833d12dfdbf57117d"),
        new("ceb", "ceb", "Cebuano", 716214, "346a39de801495c93ece6656d018d7d19d298af7db42d82ebae99dfe8ee14961"),
        new("chr", "chr", "Cherokee", 374944, "a4da60d844ebb9dbaeb8843a92290083c1fd275b167fc9c9686d790ccd311fab"),
        new("chi_sim", "zh-Hans", "Chinese (Simplified)", 2469156, "a5fcb6f0db1e1d6d8522f39db4e848f05984669172e584e8d76b6b3141e1f730"),
        new("chi_tra", "zh-Hant", "Chinese (Traditional)", 2366642, "529c5b5797d64b126065cd55f2bb4c7fd7b15790798091b1ff259941a829330b"),
        new("cos", "co", "Corsican", 2299099, "018952d1b4b3d4fd6ee5ebbacf90603c9cef6221951359937c274fe1f190f8d3"),
        new("hrv", "hr", "Croatian", 4103348, "9e515d9832ce259dbab550b1cc6b998f8b929faf2edacaaca981b05adb130571"),
        new("ces", "cs", "Czech", 3795684, "934bcaf97ef3348413263331131c9fa7f55f30db333c711929c124fb635f7e1b"),
        new("dan", "da", "Danish", 2580059, "acb1fd074487a31d1294fcdfd7d7c673467ffd8aeacb2ccd61ebcbf04eb4e2fa"),
        new("div", "dv", "Divehi", 1774535, "06051412588963b34b663cc59a468dbf10753329f015ccd574ee711e8c6b84c3"),
        new("nld", "nl", "Dutch", 6050296, "ced0e5e046a84c908a6aa7accbef9a232c4a5d9a8276691b81c6ee64d02963f6"),
        new("dzo", "dz", "Dzongkha", 449596, "364d244fad3f8d4438c9f7ee7642b9b876a4620cf76c0115619b979d6bfef1fa"),
        new("eng", "en", "English", 4113088, "7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2"),
        new("epo", "eo", "Esperanto", 4728393, "71181a6a07af3812aeedfa1aa993623424f4b8a6aac3e271b36ec11774e674d9"),
        new("est", "et", "Estonian", 4458101, "515d4a773682b286369511e83fe412bcff16a92a886f99c761c1d760a7e30456"),
        new("fao", "fo", "Faroese", 3439772, "0ed46203c283c952b7de0530d1c6e6ac9a25a79773fb89cadd149275ffea9a80"),
        new("fil", "fil", "Filipino", 1841715, "2b17f68014ab44b88b5e2334ebcd0ce0090d9af7c6fbef6fab22e0bbd9a934dd"),
        new("fin", "fi", "Finnish", 7865732, "61a04cd62b507c3d9ae0e1cda399e6715ebf49dea9df47897c8acdcd3bd3e13c"),
        new("fra", "fr", "French", 1130365, "ced037562e8c80c13122dece28dd477d399af80911a28791a66a63ac1e3445ca"),
        new("glg", "gl", "Galician", 2554555, "7947619c5544d86849f563bd737ad90dbea9f5319fbd838c4747a7a1cd40b260"),
        new("kat", "ka", "Georgian", 2524769, "557abb6f1c68bc1b286f1bdd00bb6b82f85a427a91899807dab6c2f6c7986731"),
        new("deu", "de", "German", 1525436, "19d219bbb6672c869d20a9636c6816a81eb9a71796cb93ebe0cb1530e2cdb22d"),
        new("ell", "el", "Greek", 1419514, "4fba8a0b461038d51f1c20d043d4f2ac38c4e778f1b90830847f7bd8fa3ba726"),
        new("guj", "gu", "Gujarati", 1418394, "fa69658614b4946a9afae8853d67e0689838803dfa3d12c2e35ec53ee6f8df34"),
        new("hat", "ht", "Haitian Creole", 1976902, "842e489a0e0eb12c72b5cb12e9e6624aae5928de1d097d76445474c263ce8b5a"),
        new("heb", "he", "Hebrew", 961404, "11f9e43ab227f786352a50f75c94c2e9906f1baba86d93276da19da7ce0904db"),
        new("hin", "hi", "Hindi", 1122751, "4c73ffc59d497c186b19d1e90f5d721d678ea6b2e277b719bee4e2af12271825"),
        new("hun", "hu", "Hungarian", 5296273, "35067e7cfe102dcdc953f9a758fdfaa6296b17a1ee6d874ee780fa306430b9fb"),
        new("isl", "is", "Icelandic", 2278973, "5ec828c363f3f0062c3caf08216677cf5f3c0c981b05fab445123a16b98f10a9"),
        new("ind", "id", "Indonesian", 1122661, "69786901da87ab8766c1ea7fbb10b28f2110c14da3f6c8f2735df131fba95d88"),
        new("iku", "iu", "Inuktitut", 2802266, "81ef16ee0fa0a3548c8a2d1ff10786e3278b6720e51cefd9a81a506f52660223"),
        new("gle", "ga", "Irish", 1181824, "2fe9ba6119aac7e2a20d6cfb69ed91afe9520f41bc7e3a903f84280f2663858d"),
        new("ita", "it", "Italian", 2701314, "b8f89e1e785118dac4d51ae042c029a64edb5c3ee42ef73027a6d412748d8827"),
        new("jpn", "ja", "Japanese", 2471260, "1f5de9236d2e85f5fdf4b3c500f2d4926f8d9449f28f5394472d9e8d83b91b4d"),
        new("jav", "jv", "Javanese", 2982741, "46107b6bed3bf2d9617e5e192e52524e368242543fead1a7175c363dddd400f2"),
        new("kan", "kn", "Kannada", 3608331, "bd31e6b6ae93271e3bcf5383d306d8eefbb91542937cd6d735a5930c970e61d8"),
        new("kaz", "kk", "Kazakh", 4734644, "fcc01eed3815a42b9c6321c4c9d3606f39b166cbf95ade98b7d8d12063eae53d"),
        new("khm", "km", "Khmer", 1446926, "47f110575341b322052f3becbefee61a3ecf1ef549352b5d4d33d28afe30d099"),
        new("kor", "ko", "Korean", 1677415, "6b85e11d9bbf07863b97b3523b1b112844c43e713df8b66418a081fd1060b3b2"),
        new("kir", "ky", "Kyrgyz", 9928497, "9777956300900b528d26932cf80693f95e75143433fb851d567194bcc38a31ae"),
        new("lao", "lo", "Lao", 6386744, "20124962e93e68121e02c49a949d1f9df5db87dd62e5e4aa578362ca532444f8"),
        new("lat", "la", "Latin", 3187463, "3859d8ba60404f4b79830622625bbc76fb4ee2808eac1ad360ffa77f0a533328"),
        new("lav", "lv", "Latvian", 2717247, "7d9eaf22254b381f18b806cd6cb647862a397a7221adbce3e22cc421793a8847"),
        new("lit", "lt", "Lithuanian", 3154896, "1e383df5b055583bc01cb5764ecdf74c540753f2cb3f8205e7105361da4bc989"),
        new("ltz", "lb", "Luxembourgish", 2606426, "5516a78efa30c050da7eb0727fec3de59670c19735c00678a67fdad98e4b3ec1"),
        new("mkd", "mk", "Macedonian", 1600188, "58622bf154830fa62103359938564aeb8112b929759e22a48224f3ecfaac34c6"),
        new("msa", "ms", "Malay", 1747801, "e41a3e5febfec50c90371eb1cbb17a48b10cad387900e3420b1f134c1b766cba"),
        new("mal", "ml", "Malayalam", 5275996, "bd05cbf1b197e7810d2903419aedb06f9ef77bfedf50b358673c1d18d707cdb4"),
        new("mlt", "mt", "Maltese", 2308796, "3040b443d5d49e4183da0eaaf58d1033c3a616153d35d2342a56777f9bbb31c7"),
        new("mri", "mi", "Maori", 862973, "8552be985e8fa0210d6d815d736151d645089b590a56f2d92391fb864e8bf9c9"),
        new("mar", "mr", "Marathi", 2118233, "0ba3f2d116972e72fe9e176bc84c38e81dfb6670f4ed1f7f6c8e16a27da7cb61"),
        new("mon", "mn", "Mongolian", 2137042, "a151a3806d61ac43619cd383896d551ba5c3b07388ffec6fc83c8c604d677570"),
        new("nep", "ne", "Nepali", 1002911, "280ba9450b4f21afbf5985e0de87857b75a972577c50ef0603c141ddde4f1cb8"),
        new("kmr", "kmr", "Northern Kurdish", 3568615, "a3ef2daa828399ca8d6ae69edfa21ed21aa5abb3f868e2024d3235406312e7b6"),
        new("nor", "nb", "Norwegian", 3610079, "0451eb4f8049ae78196806bf878a389a2f40f1386fe038568cf4441226ba6ef2"),
        new("oci", "oc", "Occitan", 6322087, "747b9be4c5b80b4c730ce4f426a3b85060a1bb0de54cd566fcbdcb7f407940c9"),
        new("ori", "or", "Odia", 1480066, "36f3135e61d501a3acfad41f5fe60b8e791274fff4c5375c969fdcca980cdbac"),
        new("pus", "ps", "Pashto", 1772087, "f15550bfe3a20ca781cf5afb7b2af6ee769c6521cf4bb990848e72856b484600"),
        new("fas", "fa", "Persian", 431500, "db1c0a91208aff00d3cf1ed2c1d23f76419afd5f024688b4f71adc3f2ce4a505"),
        new("pol", "pl", "Polish", 4765518, "c4476cdbc0e33d898d32345122b7be1cbf85ace15f920f06c7714756e1ef79b2"),
        new("por", "pt", "Portuguese", 1982756, "c4932b937207a9514b7514d518b931a99938c02a28a5a5a553f8599ed58b7deb"),
        new("pan", "pa", "Punjabi", 497721, "1ec0907fc3534065ea9ae190c6bb7ec9e5c74fd9d2fa996aaec7407f11ad8131"),
        new("que", "qu", "Quechua", 5026336, "9a3f78b010254ae237a7ca89e65e6d0c349221e437ac1575df1877e63a76bf57"),
        new("ron", "ro", "Romanian", 2376323, "9adfde6b51ba4b97efd10ea37c3070fd3fc2bad7815e81f5c3c198cd96216cc9"),
        new("rus", "ru", "Russian", 3861738, "e16e5e036cce1d9ec2b00063cf8b54472625b9e14d893a169e2b0dedeb4df225"),
        new("san", "sa", "Sanskrit", 12404677, "a399958921c64e7d2319369ade1e74b4db2577744ac5bfeabd16663cf743b91c"),
        new("gla", "gd", "Scottish Gaelic", 3068307, "cb7b206d9f56b601d1666683ea8a516c8bb9c04362dbb874fc9665b339b72adf"),
        new("srp", "sr-Cyrl", "Serbian (Cyrillic)", 2149931, "aa41ae3d9cc705e60d398ab38a5c3cc8b772c0d420c7d4f0859beb13d0e321b6"),
        new("srp_latn", "sr-Latn", "Serbian (Latin)", 3281787, "54b2e001bd8a336bdffc249c1487b8b7cb712f0a031f2551930ba050ebefa2a0"),
        new("snd", "sd", "Sindhi", 1694035, "f25cae3b325b0a6dc4dd5d8aeb3ac40b129a18bdd92666317022ee198f7878a7"),
        new("sin", "si", "Sinhala", 1727413, "bc75c6df2375a30c9f7e759fa7d4b58ae3ecf9ce72668a702d01acb13e551422"),
        new("slk", "sk", "Slovak", 4427661, "fbcc400a9c74c6a13d922fcb1211b655d1b165387b675ed75cd2dbd756b974a5"),
        new("slv", "sl", "Slovenian", 3003829, "b937632c17ce5fdf20535d25feec044da10a0c4c8234f4302d5606fd671cf60d"),
        new("spa", "es", "Spanish", 2294433, "6f2e04d02774a18f01bed44b1111f2cd7f3ba7ac9dc4373cd3f898a40ea6b464"),
        new("sun", "su", "Sundanese", 1369500, "fa939213b005b3477a1032b7222f63cd0b0ac486f83fd9554caf653d6e6c6ffe"),
        new("swa", "sw", "Swahili", 2167651, "395439d1ec308535066cbaea9b15e0e4cc81f8609170af76ab7e7e8d3ec42f3e"),
        new("swe", "sv", "Swedish", 4167034, "f7304988d41f833efebcc2d529df54b1903ecebbc3da1faabd19a0fddd4fe586"),
        new("syr", "syr", "Syriac", 2207208, "7435b43466da8343619bdc43c4da8dc8581f21aab3337fa1bd22ed8a8c10af04"),
        new("tgk", "tg", "Tajik", 2602685, "7b32ed1374649b9b44b9a20ed07f1e86c1e1004c3bd11ce182496a47a18cb321"),
        new("tam", "ta", "Tamil", 3237963, "d02fbec24be4b07e32e80d0ccfc3b6b67a3c5d61c9d0a7c8532677990912c6ec"),
        new("tat", "tt", "Tatar", 1072896, "7ad946d753f4b9688e4e4bcf525a931f486da4aaa9020e32b6a7262718bdf093"),
        new("tel", "te", "Telugu", 2769654, "d10691fddd5b67802e1c12800ebb321d3b8bcd8d24a2ac3ff206f93188c04ab5"),
        new("tha", "th", "Thai", 1072600, "294227cc2d1292b0acb28d61d4115c88252b96d466ca90b417cf4cf0c67bf07c"),
        new("bod", "bo", "Tibetan", 1966440, "1aab1db8dae337dfc8fa0f94a1c137c47e4c7857c3e6b30093ec726cef912a0b"),
        new("tir", "ti", "Tigrinya", 378822, "73d7430c22a062b061f603a2c1d70c4ea4aa092f7a932a97921926e15b4fdb3d"),
        new("ton", "to", "Tongan", 947249, "23d36448a3c59499da59502419ffcaa279056fa369a0fa2c798e066321d01bd1"),
        new("tur", "tr", "Turkish", 4550554, "7393381111e1152420fc4092cb44eef4237580d21b92bf30d7d221aad192c6b7"),
        new("ukr", "uk", "Ukrainian", 3825102, "d59e53e2bded32f4445f124b4b00240fcac7e8044c003ab822ccb94f0b3db59b"),
        new("urd", "ur", "Urdu", 1398718, "62e8250ce2a994106e313a82e26a516a39e2cf159d0ce3c5b5008387fd0d555f"),
        new("uig", "ug", "Uyghur", 2794272, "163b360268c39fc69e0c0dc9299c06dfe7a6c51ef8f33766da75022217b69b22"),
        new("uzb_cyrl", "uz-Cyrl", "Uzbek (Cyrillic)", 1563501, "a2fe0b3f0eb4a5e46252470160ad51cc5f3c4c0f390ba67d1911beb0dbe80cc8"),
        new("uzb", "uz-Latn", "Uzbek (Latin)", 6470703, "0e39021eefe692906b50d9bd22e580fa57fe43fa35db6846ad8b6369ddc21ea8"),
        new("vie", "vi", "Vietnamese", 531275, "79df64caf7bcfb2a27df5042ecb6121e196eada34da774956995747636d5bfa1"),
        new("cym", "cy", "Welsh", 2208919, "7f6ee3374749645a7c92dfe773f5c3d6492194d371712ecfd775edc53c363fb4"),
        new("fry", "fy", "Western Frisian", 1906018, "7c9dbc47ef3848e33b623d1b927dd4d998ed39ff750fbc0f14aeb0f627b5da15"),
        new("yid", "yi", "Yiddish", 545606, "f9a3d74076460a505dc0c6b59a0f5bd1108c6436d570954223b3695988d1666d"),
        new("yor", "yo", "Yoruba", 963400, "17ab3855f1ba9056183759a84e4c11cebf417a7d3c8c2cdcc37537d7fbffba3d"),
    ];
}
