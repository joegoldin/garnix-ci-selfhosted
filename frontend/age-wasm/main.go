package main

import (
	"errors"
	"io"
	"strings"
	"syscall/js"

	"filippo.io/age"
	"filippo.io/age/armor"
)

func main() {
	js.Global().Set("__garnixAgeEncrypt", js.FuncOf(Encrypt))
	select {}
}

func Encrypt(this js.Value, args []js.Value) interface{} {
	if len(args) != 2 {
		return errResult(errors.New("expected 2 arguments"))
	}
	publicKeys := args[0].String()
	toEncrypt := args[1].String()

	var buf strings.Builder
	armorWriter := armor.NewWriter(&buf)
	recipients, err := age.ParseRecipients(strings.NewReader(publicKeys))
	if err != nil {
		return errResult(err)
	}
	encryptWriter, err := age.Encrypt(armorWriter, recipients...)
	if err != nil {
		return errResult(err)
	}
	if _, err := io.Copy(encryptWriter, strings.NewReader(toEncrypt)); err != nil {
		return errResult(err)
	}
	if err := encryptWriter.Close(); err != nil {
		return errResult(err)
	}
	if armorWriter != nil {
		if err := armorWriter.Close(); err != nil {
			return errResult(err)
		}
	}
	return okResult(buf.String())
}

func okResult(s string) interface{} {
	output := make(map[string]interface{})
	output["ok"] = true
	output["data"] = s
	return output
}

func errResult(err error) interface{} {
	output := make(map[string]interface{})
	output["ok"] = false
	output["error"] = err.Error()
	return output
}
