use std::{env, error::Error, fs, path::Path};
use wit_component::{ComponentEncoder, StringEncoding, embed_component_metadata};
use wit_parser::Resolve;

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = env::args_os().skip(1).collect();
    if args.len() != 2 && args.len() != 3 {
        return Err("usage: flint-wasi-fixtures INPUT.wat OUTPUT.wasm [WIT-directory]".into());
    }
    let mut bytes = wat::parse_file(&args[0])?;
    if let Some(wit) = args.get(2) {
        let mut resolve = Resolve::default();
        let (package, _) = resolve.push_dir(Path::new(wit))?;
        let world = resolve.select_world(&[package], None)?;
        embed_component_metadata(&mut bytes, &resolve, world, StringEncoding::UTF8, false)?;
        bytes = ComponentEncoder::default()
            .module(&bytes)?
            .validate(true)
            .encode()?;
    }
    fs::write(&args[1], bytes)?;
    Ok(())
}
