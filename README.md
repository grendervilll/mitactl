# mitactl
Web-panel and cli-utils for mita server
Веб-панель и cli-утилита для mita сервера

Tested and works perfectly on Ubuntu 24.04. Operation on other distributions is not guaranteed.
Протестировано и отлично работает на Ubuntu 24.04. Работа на других дистрибутивах не гарантирована. 

### The panel is currently in testing; some features require further work and revision./Панель пока в стадии тестирования, есть функции, которые нужно доделывать/переделывать.


### Установка/Installation
1) Run `git clone` of this repository onto your VPS server./Сделайте `git clone` этого репозитория на свой VPS сервер
2) Change into the created folder./Перейдите в созданную папку
3) Execute the following commands/Выполните следующие команды:
   `chmod +x install-panel.sh install.sh manage-users.sh mita-ctl.sh`
   `vim install.sh` to edit the fields/для редактирования полей :
MITA_USERS=(
"alice:password"
"bob:password"
)
For these users, you **must** change the password to at least 8 characters; otherwise, an error will occur and nothing will be installed. After a successful installation, they can be removed via the Web panel or through the utility. / У этих пользователей **обязательно** необходимо сменить пароль на минимум 8-ми значиный, иначе будет ошибка и ничего не установится. После корректной установки их можно будет удалить в Веб-панели или через утилиту.
   `bash ./install.sh`
4) Follow the steps prompted by the installer./следовать предлагаемым шагам установщика



