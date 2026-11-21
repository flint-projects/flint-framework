module copy_secret;

import flint.prompt : Secret;

@safe:

private void duplicate(ref Secret owner)
{
    Secret other = owner;
    other.clear();
}
