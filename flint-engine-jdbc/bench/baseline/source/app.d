/// Control for the flint:engine-jdbc probe: the same program and output without the module (PROBE_CONTRACT.md).
module app;

import std.stdio : writeln;

@safe:

int main(string[] args)
{
    enum sqlite = "/var/data/app.db | select $1 | registered";
    enum postgres = "host='db.example' port='6543' dbname='shop' | select $1 from t where a = $2 | registered";
    writeln(args.length > 1 ? postgres : sqlite);
    return 0;
}
