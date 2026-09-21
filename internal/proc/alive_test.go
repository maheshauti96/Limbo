package proc

import "testing"

func TestListingHasPID(t *testing.T) {
	listing := `
  123 /Applications/Cursor.app/Contents/MacOS/Cursor
  456 cursor-agent worker start --name x
  789 /usr/bin/ssh-agent
`
	if !ListingHasPID(listing, 123) {
		t.Fatal("expected 123")
	}
	if !ListingHasPID(listing, 456) {
		t.Fatal("expected 456")
	}
	if ListingHasPID(listing, 999) {
		t.Fatal("did not expect 999")
	}
	if ListingHasPID(listing, 0) || ListingHasPID(listing, -1) {
		t.Fatal("invalid pid")
	}
	// Substring must not match (pid 12 must not match 123)
	if ListingHasPID(listing, 12) {
		t.Fatal("substring false positive")
	}
}

func TestAlive_listingFallback(t *testing.T) {
	// Unlikely-to-exist pid: Signal(0) fails; listing fallback succeeds.
	const fake = 987654321
	listing := "987654321 /fake/process\n"
	if !Alive(fake, listing) {
		t.Fatal("expected listing fallback")
	}
	if Alive(fake, "") {
		t.Fatal("expected dead without listing")
	}
}
