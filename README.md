# arem-mzf-parser

If you have Z80 assembler sources for the Sharp MZ 800 computer
from the 8bit era you may find this tool handy.

The script reads the assembler source stored in the AREM format.
The source should be ready in the binary MZF file (type 0x41).

## Install

```
bundle install
```

## Use

```
./arem_src_parse.rb my_source.mzf > my_source.asm.txt
```

Please open an issue if the script fails.
Do not forget to attach the exception information.

## License

MIT License.
Please see the LICENSE file for details.

