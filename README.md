# pivotal

☀️ **everything you've worked on with claude code, globally searchable and indexed.**
\
[> blog post](https://obaid.wtf/jotbook/2026/08/02/announcing-pivotal.html)


**you can forget having to look up projects and chats, pivotal makes everything you've done one-click searchable and categorizes them into topics:**

\> "convert xlx of event attendees into csv"
\
\> "estimate monthly aws bill based on bedrock tokens consumed"
\
\> "read my whatsapp chats and reply to everyone unread with, obaid will speak to you soon"
\
\> "building a claude knowledgebase called pivotal"

are all automatically found, indexed, categorized, and made accessible directly from your terminal. just do `↓ DOWN ARROW`

------

<img width="960" height="828" alt="first sr" src="https://github.com/user-attachments/assets/20157904-8d32-4205-977f-17c90866d1b4" />

------

doesn't interfere with claude code or any default keymapping.

**install, update, uninstall, and change all from the same one-liner:**

```sh
curl -fsSL https://pivotal.obaid.wtf/install.sh | bash
```

---

i've worked extremely carefully myself to make the UX as delightful and simple as I always do, and the `install.sh` experience is part of it
 
## Install

everything is handled by `install.sh`, first time it runs it will walk you through the installation, and the next time it will detect your set up and give you configuration options as well as cleanly uninstal or change your installation from prod to dev (realtime changes reflected) mode.

<img width="656" height="233" alt="Screenshot 2026-08-02 at 3 41 55 PM" src="https://github.com/user-attachments/assets/806ee214-35e3-4428-94e3-efdf9c7c0595" />

production mode

```sh
curl -fsSL https://pivotal.obaid.wtf/install.sh | bash
```

Development (you can clone anywhere; install.sh auto-detects development directory and offers to install in dev mode: realtime changes reflected):

```sh
git clone https://github.com/obaidregens/pivotal.git && cd pivotal
bash install.sh   # this install.sh auto-detects project directory and offers "Install dev version"
```

## how it works

It directly installs into your terminal, so so just doing `↓ DOWN ARROW` (unmapped key) will let you navigate through your topics like `↑ UP ARROW` does terminal history

\> search through chats by typing
\> "deep agentic search" for difficult queries where you don't remember the literal excerpt
\> topics take ~5min to index on first-install but make it extremely simple to get back into a topic.

**search everything**: just start typing in the picker — every keystroke is a literal full-text search across all your chats (local SQLite FTS5 index, zero tokens, ~25ms). Results show the matching moment with its topic; Enter continues that topic. A pinned `⚡ deep search` row sits above the results — Enter on it launches a Claude agent armed with the index (`pivotal search-json`) that probes vocabulary variants, reads the actual transcripts, and reports ranked findings. Literal search is instant, semantic depth is one keypress away, and there's no embedding pipeline to babysit.

<img width="800" height="452" alt="Screen Recording 2026-08-02 at 8 10 02 PM" src="https://github.com/user-attachments/assets/787494e6-835c-4051-a2be-83bb5ba93af1" />

the `install.sh` and `pivotal ↓ down arrow to see topics` badge after should make everything pretty self-explanatory hand-holding! but if you go off a wrong path or something is not extremely explanatory just dm me on twitter @wtfobaid or text @ +1 940-745-8318 with a link to the repo and what you went through.

## thesis
blog post introducing pivotal [here](https://obaid.wtf/jotbook/2026/08/02/announcing-pivotal.html)
