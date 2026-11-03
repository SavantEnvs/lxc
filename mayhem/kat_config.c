/* Known-answer probe for mayhem/test.sh: set liblxc config items, read them back, print them. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lxc/lxccontainer.h>

static const char *const items[][2] = {
	{ "lxc.uts.name", "katbox" },
	{ "lxc.arch", "x86_64" },
	{ "lxc.tty.max", "4" },
	{ "lxc.pty.max", "1000" },
	{ "lxc.log.level", "DEBUG" },
	{ "lxc.rootfs.path", "dir:/some/path" },
	{ "lxc.net.0.type", "veth" },
	{ "lxc.net.0.link", "br0" },
	{ "lxc.net.0.ipv4.address", "10.0.3.5/24" },
	{ "lxc.cgroup2.memory.max", "256M" },
	{ "lxc.mount.entry", "/dev/dri dev/dri none bind,optional,create=dir" },
	{ "lxc.environment", "FOO=bar" },
	{ "lxc.environment", "BAZ=qux" },
	{ "lxc.start.delay", "5" },
	{ "lxc.signal.halt", "SIGUSR1" },
};

int main(int argc, char **argv)
{
	struct lxc_container *c;
	const char *last = NULL;
	char buf[4096];
	size_t i;

	if (argc != 2) {
		fprintf(stderr, "usage: %s <lxcpath>\n", argv[0]);
		return 2;
	}

	c = lxc_container_new("kat", argv[1]);
	if (!c) {
		fprintf(stderr, "lxc_container_new failed\n");
		return 1;
	}

	for (i = 0; i < sizeof(items) / sizeof(items[0]); i++) {
		if (!c->set_config_item(c, items[i][0], items[i][1])) {
			fprintf(stderr, "set %s failed\n", items[i][0]);
			return 1;
		}
	}

	for (i = 0; i < sizeof(items) / sizeof(items[0]); i++) {
		int n;

		if (last && !strcmp(last, items[i][0]))
			continue;
		last = items[i][0];

		memset(buf, 0, sizeof(buf));
		n = c->get_config_item(c, items[i][0], buf, sizeof(buf));
		if (n < 0) {
			fprintf(stderr, "get %s failed\n", items[i][0]);
			return 1;
		}
		printf("%s=[%s]\n", items[i][0], buf);
	}

	memset(buf, 0, sizeof(buf));
	if (c->get_keys(c, "lxc.net.0", buf, sizeof(buf)) < 0)
		return 1;
	{
		static const char *const subkeys[] = { "type", "link", "hwaddr", "ipv4.address", "bogus" };
		char hay[4200];

		snprintf(hay, sizeof(hay), "\n%s", buf);
		for (i = 0; i < sizeof(subkeys) / sizeof(subkeys[0]); i++) {
			char needle[64];

			snprintf(needle, sizeof(needle), "\n%s\n", subkeys[i]);
			printf("lxc.net.0 has %s: %s\n", subkeys[i], strstr(hay, needle) ? "yes" : "no");
		}
	}

	if (!c->clear_config_item(c, "lxc.tty.max"))
		return 1;
	memset(buf, 0, sizeof(buf));
	c->get_config_item(c, "lxc.tty.max", buf, sizeof(buf));
	printf("lxc.tty.max after clear=[%s]\n", buf);

	lxc_container_put(c);
	return 0;
}
