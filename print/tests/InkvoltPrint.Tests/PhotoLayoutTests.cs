using InkvoltPrint.Core.Photos;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Tests;

public class PhotoLayoutTests
{
    private static readonly SheetPaper Letter = new(8.5, 11, 0.25, 0.25, 0.25, 0.25);
    private static readonly SheetPaper LetterBorderless = new(8.5, 11, 0, 0, 0, 0);
    private static readonly SheetPaper A4 = new(8.27, 11.69, 0.25, 0.25, 0.25, 0.25);
    private static readonly SheetPaper Photo4x6 = new(4, 6, 0.12, 0.12, 0.12, 0.12);
    private static readonly SheetPaper Photo4x6Borderless = new(4, 6, 0, 0, 0, 0);

    private static PhotoInput Landscape(int copies = 1, PhotoCrop? crop = null) => new(6000, 4000, copies, crop ?? PhotoCrop.None);
    private static PhotoInput Portrait(int copies = 1, PhotoCrop? crop = null) => new(3000, 4000, copies, crop ?? PhotoCrop.None);

    private static PhotoLayoutOptions Size(PhotoSize size, PhotoFit fit = PhotoFit.Fill, bool onePerSheet = false) =>
        new() { Kind = PhotoLayoutKind.PrintSize, Size = size, Fit = fit, OnePhotoPerSheet = onePerSheet };

    private static void Near(Placement expected, Placement actual, int digits = 6)
    {
        Assert.Equal(expected.X, actual.X, digits);
        Assert.Equal(expected.Y, actual.Y, digits);
        Assert.Equal(expected.Width, actual.Width, digits);
        Assert.Equal(expected.Height, actual.Height, digits);
    }

    // ---- Fit / fill inside a cell ----

    [Fact]
    public void Fill_covers_the_cell_and_crops_the_long_side_evenly()
    {
        var cell = new Placement(1, 1, 4, 4);
        var image = PhotoLayout.Place(cell, 6, 4, PhotoFit.Fill, PhotoCrop.None, turned: false);
        Near(new Placement(0, 1, 6, 4), image); // 6 × 4 scaled to height 4: 1 in cut off each side
    }

    [Fact]
    public void Fit_shows_the_whole_photo_centred()
    {
        var cell = new Placement(0, 0, 4, 4);
        var image = PhotoLayout.Place(cell, 6, 4, PhotoFit.Fit, PhotoCrop.None, turned: false);
        Near(new Placement(0, 2 / 3.0, 4, 8 / 3.0), image);
    }

    [Fact]
    public void Turned_photo_is_laid_out_on_its_side()
    {
        // A 6 × 4 landscape photo in a 4 × 6 portrait cell, turned: fills it exactly.
        var image = PhotoLayout.Place(new Placement(0, 0, 4, 6), 6, 4, PhotoFit.Fill, PhotoCrop.None, turned: true);
        Near(new Placement(0, 0, 4, 6), image);
    }

    [Fact]
    public void Pan_moves_the_crop_to_an_edge()
    {
        var cell = new Placement(0, 0, 4, 4);
        var right = PhotoLayout.Place(cell, 6, 4, PhotoFit.Fill, new PhotoCrop(1, 1, 0), turned: false);
        Assert.Equal(-2, right.X, 6); // the photo's right edge on the cell's right edge
        var left = PhotoLayout.Place(cell, 6, 4, PhotoFit.Fill, new PhotoCrop(1, -1, 0), turned: false);
        Assert.Equal(0, left.X, 6);
    }

    [Fact]
    public void Pan_is_kept_in_the_photos_own_frame_when_it_is_turned()
    {
        // Portrait photo 4 × 6 in a landscape 6 × 3 cell: turned, so the photo's own top (PanY = -1) is the cell's right.
        var cell = new Placement(0, 0, 6, 3);
        var top = PhotoLayout.Place(cell, 4, 6, PhotoFit.Fill, new PhotoCrop(1, 0, -1), turned: true);
        // Turned it's 6 × 4 scaled to width 6: 6 × 4, 1 in overflow vertically... the photo's x axis is the cell's y axis.
        Assert.Equal(6, top.Width, 6);
        Assert.Equal(4, top.Height, 6);
        Assert.Equal(-0.5, top.Y, 6); // PanY moves along the cell's x axis, which has no overflow: centred
        var side = PhotoLayout.Place(cell, 4, 6, PhotoFit.Fill, new PhotoCrop(1, 1, 0), turned: true);
        Assert.Equal(-1, side.Y, 6); // photo's right (PanX = 1) is the cell's bottom
    }

    [Fact]
    public void Zoom_enlarges_around_the_centre()
    {
        var cell = new Placement(0, 0, 4, 4);
        var image = PhotoLayout.Place(cell, 4, 4, PhotoFit.Fill, new PhotoCrop(2, 0, 0), turned: false);
        Near(new Placement(-2, -2, 8, 8), image);
    }

    [Fact]
    public void Dragging_pans_by_the_distance_moved_and_stops_at_the_edges()
    {
        var cell = new Placement(0, 0, 4, 4);
        var crop = PhotoCrop.None;
        // 6 × 4 filled: 2 in overflow. Dragging the photo 1 in to the right shows its left edge.
        var moved = PhotoLayout.Drag(cell, 6, 4, PhotoFit.Fill, crop, turned: false, dx: 1, dy: 0);
        Assert.Equal(-1, moved.PanX, 6);
        Assert.Equal(0, PhotoLayout.Place(cell, 6, 4, PhotoFit.Fill, moved, false).X, 6);
        var further = PhotoLayout.Drag(cell, 6, 4, PhotoFit.Fill, moved, turned: false, dx: 5, dy: 0);
        Assert.Equal(-1, further.PanX, 6);
        // No overflow vertically: dragging up and down changes nothing.
        Assert.Equal(0, PhotoLayout.Drag(cell, 6, 4, PhotoFit.Fill, crop, false, 0, 3).PanY, 6);
    }

    [Fact]
    public void Dragging_a_turned_photo_pans_it_in_its_own_frame()
    {
        // Portrait 4 × 6 photo turned into a 6 × 3 cell: 1 in overflow along the cell's height, which is the photo's x axis.
        var cell = new Placement(0, 0, 6, 3);
        var moved = PhotoLayout.Drag(cell, 4, 6, PhotoFit.Fill, PhotoCrop.None, turned: true, dx: 0, dy: 0.5);
        Assert.Equal(-1, moved.PanX, 6); // dragged down: the cell's top shows, the photo's left side
        Assert.Equal(0, PhotoLayout.Place(cell, 4, 6, PhotoFit.Fill, moved, true).Y, 6);
    }

    // ---- Print sizes on a sheet ----

    [Fact]
    public void Four_by_six_on_letter_is_two_per_sheet()
    {
        var grid = PhotoLayout.Grid(Size(PhotoSizes.In4x6), Letter, preferLandscape: true);
        Assert.Equal(2, grid.Cells.Count);
        Assert.All(grid.Cells, c => { Assert.Equal(6, c.Width, 6); Assert.Equal(4, c.Height, 6); });
        Assert.False(grid.Shrunk);
        // Inside the printable area, not overlapping, centred.
        Assert.All(grid.Cells, c => Assert.True(c.X >= 0.25 - 1e-9 && c.Y >= 0.25 - 1e-9 && c.X + c.Width <= 8.25 + 1e-9 && c.Y + c.Height <= 10.75 + 1e-9));
        Assert.True(grid.Cells[0].Y + grid.Cells[0].Height <= grid.Cells[1].Y);
        Assert.Equal(1.25, grid.Cells[0].X, 6);
    }

    [Fact]
    public void Four_by_six_on_letter_with_portrait_photos_is_two_side_by_side()
    {
        var grid = PhotoLayout.Grid(Size(PhotoSizes.In4x6), Letter, preferLandscape: false);
        Assert.Equal(2, grid.Cells.Count);
        Assert.All(grid.Cells, c => { Assert.Equal(4, c.Width, 6); Assert.Equal(6, c.Height, 6); });
        Assert.Equal(grid.Cells[0].Y, grid.Cells[1].Y, 6);
    }

    [Theory]
    [InlineData(5, 7, 2)]       // two landscape 7 × 5 stacked
    [InlineData(8, 10, 1)]
    [InlineData(2.5, 3.5, 9)]   // wallets: 3 × 3 portrait
    public void Cells_per_letter_sheet(double w, double h, int expected)
    {
        var grid = PhotoLayout.Grid(Size(new PhotoSize("test", w, h)), Letter, preferLandscape: false);
        Assert.Equal(expected, grid.Cells.Count);
    }

    [Fact]
    public void Ten_by_fifteen_cm_on_a4_is_two_per_sheet()
    {
        var grid = PhotoLayout.Grid(Size(PhotoSizes.Cm10x15), A4, preferLandscape: false);
        Assert.Equal(2, grid.Cells.Count);
        Assert.Equal(150 / 25.4, grid.Cells[0].Width, 6); // turned landscape to fit two
    }

    [Fact]
    public void Cells_are_spaced_for_cutting_when_there_is_room()
    {
        var grid = PhotoLayout.Grid(Size(PhotoSizes.Wallet), Letter, preferLandscape: false);
        var gap = grid.Cells[1].X - (grid.Cells[0].X + grid.Cells[0].Width);
        Assert.Equal(PhotoLayout.CutGap, gap, 6);
        // Rows: 3 × 3.5 = 10.5 of 10.5 in: no room, so no gap.
        Assert.Equal(grid.Cells[0].Y + 3.5, grid.Cells[3].Y, 6);
    }

    [Fact]
    public void A_size_larger_than_the_printable_area_shrinks_to_it()
    {
        var grid = PhotoLayout.Grid(Size(PhotoSizes.In4x6), Photo4x6, preferLandscape: false);
        Assert.True(grid.Shrunk);
        var cell = Assert.Single(grid.Cells);
        Assert.Equal(4 - 0.24, cell.Width, 6); // the width is what limits it
        Assert.Equal((4 - 0.24) * 6 / 4, cell.Height, 6);
    }

    [Fact]
    public void Four_by_six_borderless_on_four_by_six_paper_is_the_whole_sheet()
    {
        var grid = PhotoLayout.Grid(Size(PhotoSizes.In4x6), Photo4x6Borderless, preferLandscape: true);
        Assert.False(grid.Shrunk);
        Near(new Placement(0, 0, 4, 6), Assert.Single(grid.Cells));
    }

    [Fact]
    public void Photos_are_turned_to_their_cells_orientation()
    {
        var sheets = PhotoLayout.Sheets([Portrait(), Landscape()], Size(PhotoSizes.In4x6), Letter);
        var sheet = Assert.Single(sheets);
        // One portrait, one landscape photo: tie, so portrait cells; the landscape photo is turned.
        Assert.False(sheet.Cells[0].Turned);
        Assert.True(sheet.Cells[1].Turned);
    }

    [Fact]
    public void Square_photos_are_never_turned()
    {
        var sheets = PhotoLayout.Sheets([new PhotoInput(1000, 1000, 1, PhotoCrop.None)], Size(PhotoSizes.In4x6), Letter);
        Assert.False(sheets[0].Cells[0].Turned);
    }

    [Fact]
    public void Copies_fill_cells_in_order_and_flow_onto_more_sheets()
    {
        var sheets = PhotoLayout.Sheets([Landscape(copies: 3), Landscape(copies: 2)], Size(PhotoSizes.In4x6), Letter);
        Assert.Equal(3, sheets.Count);
        Assert.Equal([0, 0, 0, 1, 1], sheets.SelectMany(s => s.Cells).Select(c => c.Photo));
    }

    [Fact]
    public void One_photo_per_sheet_repeats_it_in_every_cell()
    {
        var sheets = PhotoLayout.Sheets([Portrait(copies: 2), Portrait()], Size(PhotoSizes.Wallet, onePerSheet: true), Letter);
        Assert.Equal(3, sheets.Count);
        Assert.All(sheets[0].Cells, c => Assert.Equal(0, c.Photo));
        Assert.Equal(9, sheets[1].Cells.Count);
        Assert.All(sheets[2].Cells, c => Assert.Equal(1, c.Photo));
    }

    [Fact]
    public void No_photos_no_sheets() => Assert.Empty(PhotoLayout.Sheets([], Size(PhotoSizes.In4x6), Letter));

    [Fact]
    public void Zero_copies_print_nothing()
    {
        Assert.Empty(PhotoLayout.Sheets([Landscape(copies: 0)], Size(PhotoSizes.In4x6), Letter));
    }

    // ---- Full page ----

    [Fact]
    public void Full_page_turns_a_landscape_photo_on_portrait_paper()
    {
        var sheets = PhotoLayout.Sheets([Landscape(copies: 2)], new PhotoLayoutOptions { Kind = PhotoLayoutKind.FullPage, Fit = PhotoFit.Fit }, Letter);
        Assert.Equal(2, sheets.Count);
        var cell = Assert.Single(sheets[0].Cells);
        Assert.True(cell.Turned);
        Near(new Placement(0.25, 0.25, 8, 10.5), cell.Cell);
        // 6000 × 4000 turned is 4000 × 6000 wide: fits 8 wide (12 tall > 10.5, so height bound): 7 × 10.5.
        Near(new Placement(0.25 + 0.5, 0.25, 7, 10.5), cell.Image);
    }

    [Fact]
    public void Full_page_fill_borderless_covers_the_paper()
    {
        var sheets = PhotoLayout.Sheets([Portrait()], new PhotoLayoutOptions { Kind = PhotoLayoutKind.FullPage, Fit = PhotoFit.Fill }, LetterBorderless);
        var cell = sheets[0].Cells[0];
        Assert.True(cell.Image.Width >= 8.5 - 1e-9 && cell.Image.Height >= 11 - 1e-9);
        Near(new Placement(0, 0, 8.5, 11), cell.Cell);
    }

    // ---- Contact sheet ----

    [Theory]
    [InlineData(6, 2, 3)]
    [InlineData(12, 3, 4)]
    [InlineData(20, 4, 5)]
    [InlineData(30, 5, 6)]
    [InlineData(48, 6, 8)]
    public void Contact_grid_on_portrait_paper(int n, int cols, int rows) =>
        Assert.Equal((cols, rows), PhotoLayout.ContactGrid(n, 8, 10.5));

    [Fact]
    public void Contact_grid_on_landscape_paper_has_more_columns() => Assert.Equal((4, 3), PhotoLayout.ContactGrid(12, 10.5, 8));

    [Fact]
    public void Contact_sheet_shows_each_photo_once_whole_with_its_name()
    {
        var photos = Enumerable.Range(0, 14).Select(i => i % 2 == 0 ? Landscape(copies: 3) : Portrait()).ToList();
        var sheets = PhotoLayout.Sheets(photos, new PhotoLayoutOptions { Kind = PhotoLayoutKind.ContactSheet, PerSheet = 12, Fit = PhotoFit.Fill }, Letter);
        Assert.Equal(2, sheets.Count);
        Assert.Equal(12, sheets[0].Cells.Count);
        Assert.Equal(2, sheets[1].Cells.Count);
        foreach (var c in sheets.SelectMany(s => s.Cells))
        {
            Assert.False(c.Turned);
            Assert.NotNull(c.Caption);
            // Whole photo inside its cell, above its caption.
            Assert.True(c.Image.X >= c.Cell.X - 1e-9 && c.Image.X + c.Image.Width <= c.Cell.X + c.Cell.Width + 1e-9);
            Assert.True(c.Image.Y + c.Image.Height <= c.Caption!.Value.Y + 1e-9);
            Assert.True(c.Caption.Value.Y + c.Caption.Value.Height <= c.Cell.Y + c.Cell.Height + 1e-9);
        }
    }

    // ---- Print resolution ----

    [Fact]
    public void Dpi_is_pixels_across_the_printed_width()
    {
        Assert.Equal(1000, PhotoLayout.Dpi(6000, 4000, new Placement(0, 0, 6, 4), turned: false), 6);
        // Turned: the photo's 6000 px run along the box's height.
        Assert.Equal(2000, PhotoLayout.Dpi(6000, 4000, new Placement(0, 0, 2, 3), turned: true), 6);
        Assert.Equal(0, PhotoLayout.Dpi(6000, 4000, new Placement(0, 0, 0, 0), turned: false));
    }

    [Theory]
    [InlineData(6000, 6, 300, 1800)]   // 1000 dpi photo: decode at 300 dpi
    [InlineData(1200, 6, 300, 1200)]   // already below: as is
    [InlineData(6000, 0, 300, 6000)]
    public void Decode_width_caps_the_print_resolution(int pixels, double inches, int maxDpi, int expected) =>
        Assert.Equal(expected, PhotoLayout.DecodeWidth(pixels, inches, maxDpi));
}

public class ExifOrientationTests
{
    [Theory]
    [InlineData(1, 0, false)]
    [InlineData(2, 0, true)]
    [InlineData(3, 2, false)]
    [InlineData(4, 2, true)]
    [InlineData(5, 3, true)]
    [InlineData(6, 1, false)]
    [InlineData(7, 1, true)]
    [InlineData(8, 3, false)]
    [InlineData(0, 0, false)]  // missing or bad: as stored
    [InlineData(9, 0, false)]
    public void Turns_and_mirror(int orientation, int turns, bool mirror) =>
        Assert.Equal((turns, mirror), ExifOrientation.Transform(orientation));

    [Theory]
    [InlineData(1, 0, 4000, 3000)]
    [InlineData(6, 0, 3000, 4000)]
    [InlineData(6, 1, 4000, 3000)]   // EXIF turn plus a user turn
    [InlineData(1, 3, 3000, 4000)]
    [InlineData(1, -1, 3000, 4000)]  // a turn left is three right
    public void Oriented_size(int orientation, int userTurns, int w, int h) =>
        Assert.Equal((w, h), ExifOrientation.Oriented(4000, 3000, orientation, userTurns));
}

public class PhotoPaperTextTests
{
    [Theory]
    [InlineData("NorthAmericaLetter", 8.5, 11, "Letter (8.5 × 11 in)")]
    [InlineData("ISOA4", 8.27, 11.69, "A4 (21 × 29.7 cm)")]
    [InlineData("NorthAmerica4x6", 4, 6, "4 × 6 in photo")]
    [InlineData(null, 5, 7, "5 × 7 in photo")]
    [InlineData("Custom", 3.94, 5.91, "10 × 15 cm photo")]
    [InlineData("Custom", 5.12, 7.09, "13 × 18 cm photo")]
    [InlineData("NorthAmericaLegal", 8.5, 14, "Legal (8.5 × 14 in)")]
    [InlineData("Odd", 3.3, 9.1, "3.3 × 9.1 in")]
    [InlineData("JapanHagakiPostcard", 3.94, 5.83, "Hagaki postcard (10 × 14.8 cm)")]
    public void Paper_labels(string? name, double w, double h, string expected) => Assert.Equal(expected, PhotoPaperText.Paper(name, w, h));

    [Fact]
    public void Paper_label_ignores_orientation() =>
        Assert.Equal("Letter (8.5 × 11 in)", PhotoPaperText.Paper(null, 11, 8.5));

    [Theory]
    [InlineData("Plain", "Plain paper")]
    [InlineData("Photographic", "Photo paper")]
    [InlineData("PhotographicGlossy", "Photo paper, glossy")]
    [InlineData("PhotographicHighGloss", "Photo paper, high gloss")]
    [InlineData("PhotographicSemiGloss", "Photo paper, semi-gloss")]
    [InlineData("PhotographicMatte", "Photo paper, matte")]
    [InlineData("PhotographicSatin", "Photo paper, satin")]
    [InlineData("AutoSelect", "Let the printer choose")]
    [InlineData("CardStockCoated", "Card stock coated")]
    [InlineData("Envelope", "Envelope")]
    public void Media_type_labels(string name, string expected) => Assert.Equal(expected, PhotoPaperText.MediaType(name));

    [Theory]
    [InlineData("Photographic", true)]
    [InlineData("PhotographicGlossy", true)]
    [InlineData("Plain", false)]
    public void Photo_media(string name, bool photo) => Assert.Equal(photo, PhotoPaperText.IsPhotoMedia(name));

    [Theory]
    [InlineData("Draft", "Draft")]
    [InlineData("Normal", "Normal")]
    [InlineData("High", "High")]
    [InlineData("Photographic", "Photo (best)")]
    [InlineData("Automatic", "Automatic")]
    public void Quality_labels(string name, string expected) => Assert.Equal(expected, PhotoPaperText.Quality(name));

    [Theory]
    [InlineData("Color", "Color")]
    [InlineData("Grayscale", "Shades of grey")]
    [InlineData("Monochrome", "Black and white")]
    public void Color_labels(string name, string expected) => Assert.Equal(expected, PhotoPaperText.Color(name));

    [Fact]
    public void Standard_sizes_are_listed_short_side_first()
    {
        Assert.Equal(6, PhotoSizes.All.Count);
        Assert.All(PhotoSizes.All, s => Assert.True(s.Width <= s.Height));
        Assert.Contains(PhotoSizes.All, s => s.Name == "Wallet (2.5 × 3.5 in)");
    }
}
