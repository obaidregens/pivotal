# pivotal

☀️ **everything you've worked on with claude code, globally searchable and indexed.**
\
[> blog post](https://obaid.wtf/jotbook/2026/08/02/announcing-pivotal.html)


**you can forget the concept of project and chats, pivotal categorizes everything into topics:**

\> "convert xlx of event attendees into csv"
\
\> "estimate monthly aws bill based on bedrock tokens consumed"
\
\> "read my whatsapp chats and reply to everyone unread with, obaid will speak to you soon"
\
\> "building a claude knowledgebase called pivotal"

are all automatically found, indexed, categorized, and made accessible directly from your terminal. just do `↓ DOWN ARROW`

------

<img width="800" height="465" alt="Screen Recording 2026-08-02" src="https://github.com/user-attachments/assets/5a01a994-85bf-4600-b738-e5201f817648" />

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

<img width="800" height="452" alt="Screen Recording 2026-08-02 at 8 10 02 PM" src="https://github.com/user-attachments/assets/787494e6-835c-4051-a2be-83bb5ba93af1" />

the `install.sh` and `pivotal ↓ down arrow to see topics` badge after should make everything pretty self-explanatory hand-holding! but if you go off a wrong path or something is not extremely explanatory just dm me on twitter @wtfobaid or text @ +1 940-745-8318 with a link to the repo and what you went through.

**why not openclaw?**

the first time I used it, it ate an absurd amount of tokens and then proceeded to accidentally wipe my entire work for the day. i think claude code's context isolation is better, although the lack of fluidity between work is something I've tried to strike a balance with in pivotal. 

feel free to hammer me with all the detailed reasoning for why pivotal is reinventing the openclaw wheel, i might not reply but I will read all of it earnestly and think about it deeply.

## thesis
blog post introducing pivotal [here](https://obaid.wtf/jotbook/2026/08/02/announcing-pivotal.html)

---

```sh
bash install.sh --uninstall-hook
```
