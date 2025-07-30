# tktts

A Rust command-line tool that generates zhiliao Text-to-Speech audio

## Setup steps

1. Have TIKTOK_SESSIONID in your environment for wherever you execute this tool.
2. Have TIKTOK_API_BASEURL in your environment for wherever you execute this tool.
  - Will probably correspond to your `store_idc` in your cookies on tiktok.com
  - probably a url starting with `api16-normal`. can probably sniff via Charles or similar.
  - example: `https://api16-normal-useast1a.tiktokv.com`
3. Build the project with `cargo build --release`, or install with `cargo install --path .`.
4. Run the tool with `tktts "your text here"`.
# tktts
