import std.getopt;

void main()
{
    bool opt;
    string[] args = ["program"];
    getopt(args, config.passThrough, 'a', &opt);
}
